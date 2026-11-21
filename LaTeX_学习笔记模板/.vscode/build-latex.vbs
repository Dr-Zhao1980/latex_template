Option Explicit
' Permanent no-window launcher. Run with wscript.exe //B //Nologo.
' The launcher waits for compilation to finish so LaTeX Workshop gets the exit status.
On Error Resume Next
Dim shell, fs, root, mainFile, texBin, ps, runner, command, result, logFolder, logFile, message, stream
If WScript.Arguments.Count < 2 Then WScript.Quit 64
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
If Err.Number <> 0 Then WScript.Quit 1
mainFile = WScript.Arguments.Item(0)
root = WScript.Arguments.Item(1)
texBin = ""
If WScript.Arguments.Count >= 3 Then texBin = WScript.Arguments.Item(2)
runner = fs.BuildPath(fs.BuildPath(root, ".vscode"), "build-latex.ps1")
If Not fs.FileExists(runner) Then WScript.Quit 2
ps = fs.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fs.FileExists(ps) Then ps = "powershell.exe"
command = QuoteArgument(ps) & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & QuoteArgument(runner) & " -MainFile " & QuoteArgument(mainFile) & " -ProjectRoot " & QuoteArgument(root)
If Len(Trim(texBin)) > 0 Then command = command & " -TeXBin " & QuoteArgument(texBin)
Err.Clear
result = shell.Run(command, 0, True)
If Err.Number <> 0 Then
    message = "Hidden launcher could not execute PowerShell: " & CStr(Err.Number) & " " & Err.Description
    Err.Clear
    logFolder = fs.BuildPath(root, "build")
    If Not fs.FolderExists(logFolder) Then fs.CreateFolder logFolder
    If fs.FolderExists(logFolder) Then
        logFile = fs.BuildPath(logFolder, "launcher-error.log")
        Set stream = fs.OpenTextFile(logFile, 8, True)
        If Not stream Is Nothing Then
            stream.WriteLine Now & " " & message
            stream.Close
        End If
    End If
    WScript.Quit 1
End If
WScript.Quit result

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function