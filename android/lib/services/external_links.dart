import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/utils/logger.dart';
import 'package:url_launcher/url_launcher.dart';

const _log = AppLogger('Links');

/// Opens [url] in the browser (Ko-fi, GitHub). Returns false when no app
/// could open it.
Future<bool> openExternalUrl(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (error) {
    _log.w('Could not open $url', error);
    return false;
  }
}

/// A new GitHub issue with [title] and [body] filled in. Nothing is sent:
/// the user reviews and submits it in the browser. The body is cut so the
/// URL stays under browsers' length limits.
Uri githubIssueUrl({required String title, required String body}) {
  const maxBody = 6000;
  final trimmed = body.length > maxBody
      ? '${body.substring(0, maxBody)}\n…'
      : body;
  return Uri.parse(
    AppInfo.issuesUrl,
  ).replace(queryParameters: {'title': title, 'body': trimmed});
}

/// Adds the GPL-3.0 (Kalao) and LGPL-3.0 (Mornye) texts to the licences
/// page next to the packages' own licences.
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      AppInfo.appName,
    ], await rootBundle.loadString('assets/licenses/GPL-3.0.txt'));
    yield LicenseEntryWithLineBreaks(
      ['Mornye'],
      '${AppInfo.mornyeCredit}\n\n'
      '${await rootBundle.loadString('assets/licenses/LGPL-3.0.txt')}',
    );
  });
}
