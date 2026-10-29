function Show-IdsNativeFolderDialog {
    param([hashtable]$Holder, [string]$InitialPath)
    if (-not $IsWindows) { throw 'Native folder selection is available only on Windows. Enter a host folder path instead.' }
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('Ids.FolderDialogNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Ids {
    public static class FolderDialogNative {
        public delegate bool WindowVisitor(IntPtr window, IntPtr state);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint id, WindowVisitor visitor, IntPtr state);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
        public static void Close(uint id) {
            if (id != 0) EnumThreadWindows(id, (window, state) => {
                PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
                return true;
            }, IntPtr.Zero);
        }
    }
}
'@
    }
    $Holder.threadId = [Ids.FolderDialogNative]::GetCurrentThreadId()
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = 'Choose a folder on the computer running Intune Docs Studio'
        if ($InitialPath -and [IO.Directory]::Exists($InitialPath)) { $dialog.SelectedPath = $InitialPath }
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            return @{ status = 'selected'; path = $dialog.SelectedPath }
        }
        return @{ status = 'cancelled'; path = $null }
    } finally { $dialog.Dispose(); $Holder.threadId = 0 }
}

function Start-IdsFolderPicker {
    param([hashtable]$State, [string]$Root, [string]$InitialPath, [scriptblock]$Dialog)
    Sync-IdsFolderPicker $State
    if ($State.FolderPicker.status -eq 'running' -or $State.FolderPicker.job) { return $false }
    $holder = [hashtable]::Synchronized(@{ status = 'running'; path = $null; error = $null; threadId = 0; job = $null })
    $State.FolderPicker = $holder
    $worker = {
        param($Root, $Holder, $InitialPath, $DialogScript)
        $ErrorActionPreference = 'Stop'
        try {
            . (Join-Path $Root 'lib\LocalFolders.ps1')
            $result = if ($DialogScript) { & ([scriptblock]::Create($DialogScript)) $InitialPath } else { Show-IdsNativeFolderDialog $Holder $InitialPath }
            if ($result.status -notin @('selected', 'cancelled')) { throw 'Folder picker returned an invalid result.' }
            if ($result.status -eq 'selected') {
                if (-not [IO.Path]::IsPathFullyQualified($result.path) -or -not [IO.Directory]::Exists($result.path)) {
                    throw 'The selected folder is no longer available. Enter a host folder path instead.'
                }
                $Holder.path = $result.path
            }
            $Holder.status = $result.status
        } catch {
            $Holder.status = 'failed'
            $Holder.error = 'Could not open or complete the native folder picker. Enter a folder path on the application host instead.'
        }
    }
    $rs = $null; $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $dialogScript = if ($Dialog) { $Dialog.ToString() } else { $null }
        [void]$ps.AddScript($worker).AddArgument($Root).AddArgument($holder).AddArgument($InitialPath).AddArgument($dialogScript)
        $holder.job = @{ ps = $ps; runspace = $rs; handle = $ps.BeginInvoke() }
        return $true
    } catch {
        if ($ps) { $ps.Dispose() }; if ($rs) { $rs.Dispose() }
        $holder.status = 'failed'; $holder.error = 'Could not start folder selection. Enter the host folder path manually.'
        return $false
    }
}

function Sync-IdsFolderPicker {
    param([hashtable]$State)
    $job = $State.FolderPicker.job
    if (-not $job -or -not $job.handle.IsCompleted) { return }
    try { [void]$job.ps.EndInvoke($job.handle) } catch {
        $State.FolderPicker.status = 'failed'; $State.FolderPicker.error = 'Folder selection ended unexpectedly; enter the path manually.'
    } finally { $job.ps.Dispose(); $job.runspace.Dispose(); $State.FolderPicker.job = $null }
}

function Stop-IdsFolderPicker {
    param([hashtable]$State)
    $job = $State.FolderPicker.job
    if (-not $job) { return }
    if ($State.FolderPicker.threadId -and ('Ids.FolderDialogNative' -as [type])) {
        [Ids.FolderDialogNative]::Close($State.FolderPicker.threadId)
    }
    try { $job.ps.Stop() } finally { $job.ps.Dispose(); $job.runspace.Dispose(); $State.FolderPicker.job = $null }
    $State.FolderPicker.status = 'cancelled'; $State.FolderPicker.path = $null
}
