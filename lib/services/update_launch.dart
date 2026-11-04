import 'dart:convert';

String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";
String _encodedPowerShell(String command) => base64Encode([
  for (final unit in command.codeUnits) ...[unit & 255, (unit >> 8) & 255],
]);

String updateBootstrapCommand(String bootstrapPath, String requestPath) {
  return _encodedPowerShell(
    '& ${_psQuote(bootstrapPath)} -RequestPath ${_psQuote(requestPath)}',
  );
}

String updateWorkerLaunchCommand(
  String powershell,
  String bootstrapPath,
  String requestPath,
) {
  final child = updateBootstrapCommand(bootstrapPath, requestPath);
  final command =
      r"$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "
      r'$worker = Start-Process -FilePath '
      '${_psQuote(powershell)} '
      "-ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',"
      "'-EncodedCommand',${_psQuote(child)}) "
      '-WindowStyle Hidden -PassThru; '
      r"if ($null -eq $worker) { throw 'Worker process was not created.' }; "
      r"Write-Output ('WORKER_PID=' + $worker.Id);";
  return _encodedPowerShell(command);
}
