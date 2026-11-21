// Worker/VM split and limits follow Mornye's extension runtime
// (https://github.com/mornyeapp/Mornye, Copyright 2026 zarzet, LGPL-3.0-only).
// Modified for Kalao.
//! One QuickJS runtime per extension on its own worker thread (EXTENSIONS.md
//! §5). No QuickJS value leaves the worker; calls go in as JSON and come back
//! as JSON. Every call has a deadline enforced by the interrupt handler and by
//! the host calls; a VM that was interrupted or ran out of memory is retired,
//! and the manager starts a fresh one for the next call.

pub(crate) mod host;
#[cfg(test)]
mod tests;

use crate::Error;
use crate::package::{ENTRY_POINT, Package};
pub use host::HostContext;
use rquickjs::loader::{ImportAttributes, Loader, Resolver};
use rquickjs::module::Declared;
use rquickjs::{
    CatchResultExt, CaughtError, Context, Ctx, Function, Module, Object, Persistent, Value,
};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const PRELUDE: &str = include_str!("prelude.js");
const MAX_RESULT_BYTES: usize = 8 << 20;
/// Extra time the caller waits for the worker's own timeout reply.
const REPLY_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Debug)]
pub struct Limits {
    pub memory_bytes: usize,
    pub stack_bytes: usize,
    /// Loading the modules (top-level code included).
    pub load_timeout: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            memory_bytes: 64 << 20,
            stack_bytes: 1 << 20,
            load_timeout: Duration::from_secs(10),
        }
    }
}

/// Shared by the caller, the worker, the interrupt handler and host calls.
pub(crate) struct Control {
    deadline: Mutex<Instant>,
    interrupted: AtomicBool,
    closed: AtomicBool,
}

impl Control {
    fn new() -> Self {
        Self {
            deadline: Mutex::new(Instant::now()),
            interrupted: AtomicBool::new(false),
            closed: AtomicBool::new(false),
        }
    }

    pub(crate) fn deadline(&self) -> Instant {
        *self.deadline.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn set_deadline(&self, deadline: Instant) {
        *self.deadline.lock().unwrap_or_else(PoisonError::into_inner) = deadline;
    }

    /// The interrupt handler: true stops the running script.
    fn interrupt(&self) -> bool {
        if self.closed.load(Ordering::Acquire) || Instant::now() >= self.deadline() {
            self.interrupted.store(true, Ordering::Release);
            return true;
        }
        false
    }

    /// For host calls between scripts steps.
    pub(crate) fn check(&self) -> Result<(), String> {
        if self.closed.load(Ordering::Acquire) {
            return Err("extension runtime closed".into());
        }
        if Instant::now() >= self.deadline() {
            return Err("execution timeout exceeded".into());
        }
        Ok(())
    }
}

struct Call {
    function: String,
    arguments: String,
    deadline: Instant,
    reply: SyncSender<Result<String, Error>>,
}

pub struct Runtime {
    sender: Mutex<Option<SyncSender<Call>>>,
    control: Arc<Control>,
    retired: Arc<AtomicBool>,
    worker: Mutex<Option<JoinHandle<()>>>,
    exports: Vec<String>,
}

impl Runtime {
    /// Compiles and evaluates the package's modules, then reports the
    /// functions `index.js` exports.
    pub fn start(package: &Package, host: HostContext, limits: Limits) -> Result<Self, Error> {
        let files: Arc<BTreeMap<String, Vec<u8>>> = Arc::new(package.files.clone());
        let control = Arc::new(Control::new());
        let retired = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = mpsc::sync_channel::<Call>(16);
        let (ready_sender, ready) = mpsc::sync_channel(1);
        let worker = {
            let (control, retired) = (control.clone(), retired.clone());
            let host = Arc::new(host);
            let limits = limits.clone();
            std::thread::Builder::new()
                .name(format!("kalao-ext-{}", package.manifest.id))
                .stack_size(8 << 20)
                .spawn(move || {
                    run(
                        &files,
                        &host,
                        &control,
                        &retired,
                        &limits,
                        &ready_sender,
                        &receiver,
                    )
                })
                .map_err(|error| Error::Script(error.to_string()))?
        };
        let exports = match ready.recv_timeout(limits.load_timeout + REPLY_GRACE) {
            Ok(result) => result?,
            Err(_) => {
                control.closed.store(true, Ordering::Release);
                return Err(Error::Timeout);
            }
        };
        Ok(Self {
            sender: Mutex::new(Some(sender)),
            control,
            retired,
            worker: Mutex::new(Some(worker)),
            exports,
        })
    }

    pub fn exports(&self) -> &[String] {
        &self.exports
    }

    pub fn exports_function(&self, name: &str) -> bool {
        self.exports.iter().any(|export| export == name)
    }

    /// Whether a timeout, an out-of-memory error or a shutdown ended this VM.
    pub fn is_retired(&self) -> bool {
        self.retired.load(Ordering::Acquire)
    }

    /// Calls an exported function with one JSON argument; awaits a returned
    /// promise. `timeout` covers the time queued behind other calls.
    pub fn call(&self, function: &str, argument: &str, timeout: Duration) -> Result<String, Error> {
        if !self.exports_function(function) {
            return Err(Error::MissingFunction(function.to_owned()));
        }
        let deadline = Instant::now() + timeout;
        let (reply, response) = mpsc::sync_channel(1);
        let sender = self
            .sender
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .ok_or(Error::Closed)?;
        sender
            .send(Call {
                function: function.to_owned(),
                arguments: argument.to_owned(),
                deadline,
                reply,
            })
            .map_err(|_| Error::Closed)?;
        match response.recv_timeout(timeout + REPLY_GRACE) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // A host call ignored the deadline; stop the VM.
                self.shutdown();
                Err(Error::Timeout)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(Error::Closed),
        }
    }

    /// Stops the worker; queued calls fail with `Closed`.
    pub fn shutdown(&self) {
        self.control.closed.store(true, Ordering::Release);
        self.retired.store(true, Ordering::Release);
        self.sender
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.shutdown();
        if let Some(worker) = self
            .worker
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            // A worker blocked in a host call notices `closed` on its own; do
            // not wait for it here.
            drop(worker);
        }
    }
}

fn run(
    files: &Arc<BTreeMap<String, Vec<u8>>>,
    host: &Arc<HostContext>,
    control: &Arc<Control>,
    retired: &AtomicBool,
    limits: &Limits,
    ready: &SyncSender<Result<Vec<String>, Error>>,
    receiver: &Receiver<Call>,
) {
    let vm = match Vm::load(files, host, control, limits) {
        Ok(vm) => vm,
        Err(error) => {
            retired.store(true, Ordering::Release);
            let _ = ready.send(Err(error));
            return;
        }
    };
    if ready.send(Ok(vm.exports.clone())).is_err() {
        return;
    }
    while let Ok(call) = receiver.recv() {
        if control.closed.load(Ordering::Acquire) {
            let _ = call.reply.send(Err(Error::Closed));
            break;
        }
        if Instant::now() >= call.deadline {
            let _ = call.reply.send(Err(Error::Timeout));
            continue;
        }
        control.set_deadline(call.deadline);
        let result = vm.call(&call.function, &call.arguments, control);
        let fatal = control.interrupted.load(Ordering::Acquire)
            || matches!(&result, Err(Error::Script(message)) if message.contains("out of memory"));
        if fatal {
            retired.store(true, Ordering::Release);
        }
        let _ = call.reply.send(result);
        if fatal {
            break;
        }
        vm.runtime.run_gc();
    }
}

struct Vm {
    namespace: Persistent<Object<'static>>,
    exports: Vec<String>,
    context: Context,
    // Dropped after the context and its persistent values.
    runtime: rquickjs::Runtime,
}

impl Vm {
    fn load(
        files: &Arc<BTreeMap<String, Vec<u8>>>,
        host: &Arc<HostContext>,
        control: &Arc<Control>,
        limits: &Limits,
    ) -> Result<Self, Error> {
        let script = |error: rquickjs::Error| Error::Script(error.to_string());
        let runtime = rquickjs::Runtime::new().map_err(script)?;
        runtime.set_memory_limit(limits.memory_bytes);
        runtime.set_max_stack_size(limits.stack_bytes);
        let interrupt = control.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || interrupt.interrupt())));
        runtime.set_loader(PackageResolver(files.clone()), PackageLoader(files.clone()));
        let context = Context::full(&runtime).map_err(script)?;
        control.set_deadline(Instant::now() + limits.load_timeout);
        let source = files
            .get(ENTRY_POINT)
            .cloned()
            .ok_or_else(|| Error::Script("index.js is missing".into()))?;
        let (namespace, exports) = context.with(|ctx| -> Result<_, Error> {
            let host = host.clone();
            let host_control = control.clone();
            let host_fn = Function::new(
                ctx.clone(),
                move |ctx: Ctx<'_>, op: String, args: String| -> rquickjs::Result<String> {
                    match host.dispatch(&host_control, &op, &args) {
                        Ok(value) => Ok(value.to_string()),
                        Err(message) => Err(rquickjs::Exception::throw_message(&ctx, &message)),
                    }
                },
            )
            .map_err(script)?;
            let prelude: Function = ctx
                .eval(PRELUDE)
                .catch(&ctx)
                .map_err(|error| caught(error, control))?;
            prelude
                .call::<_, ()>((host_fn,))
                .catch(&ctx)
                .map_err(|error| caught(error, control))?;
            let (module, promise) = Module::declare(ctx.clone(), ENTRY_POINT, source)
                .catch(&ctx)
                .map_err(|error| caught(error, control))?
                .eval()
                .catch(&ctx)
                .map_err(|error| caught(error, control))?;
            promise
                .finish::<()>()
                .catch(&ctx)
                .map_err(|error| caught(error, control))?;
            let namespace = module.namespace().map_err(script)?;
            let mut exports = Vec::new();
            for key in namespace.keys::<String>() {
                let key = key.map_err(script)?;
                let value: Value = namespace.get(&key).map_err(script)?;
                if value.is_function() {
                    exports.push(key);
                }
            }
            exports.sort();
            Ok((Persistent::save(&ctx, namespace), exports))
        })?;
        Ok(Self {
            namespace,
            exports,
            context,
            runtime,
        })
    }

    fn call(&self, function: &str, arguments: &str, control: &Control) -> Result<String, Error> {
        self.context.with(|ctx| {
            let namespace = self
                .namespace
                .clone()
                .restore(&ctx)
                .map_err(|error| Error::Script(error.to_string()))?;
            let function: Function = namespace
                .get(function)
                .map_err(|_| Error::MissingFunction(function.to_owned()))?;
            let argument = ctx
                .json_parse(arguments)
                .catch(&ctx)
                .map_err(|error| caught(error, control))?;
            let mut result: Value = function
                .call((argument,))
                .catch(&ctx)
                .map_err(|error| caught(error, control))?;
            if let Some(promise) = result.as_promise() {
                result = promise
                    .finish::<Value>()
                    .catch(&ctx)
                    .map_err(|error| caught(error, control))?;
            }
            let json = ctx
                .json_stringify(result)
                .catch(&ctx)
                .map_err(|error| caught(error, control))?
                .map(|text| text.to_string())
                .transpose()
                .map_err(|error| Error::Script(error.to_string()))?
                .unwrap_or_else(|| "null".to_owned());
            if json.len() > MAX_RESULT_BYTES {
                return Err(Error::Script("result is larger than 8 MiB".into()));
            }
            Ok(json)
        })
    }
}

fn caught(error: CaughtError<'_>, control: &Control) -> Error {
    if control.interrupted.load(Ordering::Acquire) {
        return Error::Timeout;
    }
    match error {
        CaughtError::Error(rquickjs::Error::WouldBlock) => {
            Error::Script("the returned promise never settled".into())
        }
        CaughtError::Exception(exception) => {
            let message = exception.message().unwrap_or_else(|| "script error".into());
            match exception.stack() {
                Some(stack) if !stack.trim().is_empty() => {
                    Error::Script(format!("{message}\n{}", stack.trim_end()))
                }
                _ => Error::Script(message),
            }
        }
        CaughtError::Value(value) => Error::Script(
            value
                .as_string()
                .and_then(|text| text.to_string().ok())
                .unwrap_or_else(|| format!("thrown {}", value.type_name())),
        ),
        CaughtError::Error(error) => Error::Script(error.to_string()),
    }
}

/// Relative imports inside the package only (`./lib/x.js`, `../y.js`).
struct PackageResolver(Arc<BTreeMap<String, Vec<u8>>>);

impl Resolver for PackageResolver {
    fn resolve<'js>(
        &mut self,
        _ctx: &Ctx<'js>,
        base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        if !(name.starts_with("./") || name.starts_with("../")) {
            return Err(rquickjs::Error::new_resolving_message(
                base,
                name,
                "only relative imports inside the package are allowed",
            ));
        }
        let mut segments: Vec<&str> = base.split('/').collect();
        segments.pop();
        for segment in name.split('/') {
            match segment {
                "." | "" => {}
                ".." => {
                    if segments.pop().is_none() {
                        return Err(rquickjs::Error::new_resolving_message(
                            base,
                            name,
                            "import leaves the package",
                        ));
                    }
                }
                other => segments.push(other),
            }
        }
        let path = segments.join("/");
        if !(path.ends_with(".js") || path.ends_with(".mjs")) || !self.0.contains_key(&path) {
            return Err(rquickjs::Error::new_resolving_message(
                base,
                name,
                "no such module in the package",
            ));
        }
        Ok(path)
    }
}

struct PackageLoader(Arc<BTreeMap<String, Vec<u8>>>);

impl Loader for PackageLoader {
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        path: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<Module<'js, Declared>> {
        let source = self
            .0
            .get(path)
            .cloned()
            .ok_or_else(|| rquickjs::Error::new_loading(path))?;
        Module::declare(ctx.clone(), path, source)
    }
}
