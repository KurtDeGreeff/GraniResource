#region Initialize

function Initialize
{
    # Enum for Ensure
    Add-Type -TypeDefinition @"
        public enum EnsureType
        {
            Present,
            Absent
        }
"@ -ErrorAction SilentlyContinue

    # GetSymbolicLink Class
    $GetSymLink = @'
        private const int FILE_SHARE_READ = 1;
        private const int FILE_SHARE_WRITE = 2;
        private const int CREATION_DISPOSITION_OPEN_EXISTING = 3;
        private const int FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

        [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int GetFinalPathNameByHandle(IntPtr handle, [In, Out] StringBuilder path, int bufLen, int flags);

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(string lpFileName, int dwDesiredAccess, int dwShareMode, IntPtr SecurityAttributes, int dwCreationDisposition, int dwFlagsAndAttributes, IntPtr hTemplateFile);

        public static string GetSymbolicLinkTarget(System.IO.DirectoryInfo symlink)
        {
            SafeFileHandle directoryHandle = CreateFile(symlink.FullName, 0, 2, System.IntPtr.Zero, CREATION_DISPOSITION_OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, System.IntPtr.Zero);

            if (directoryHandle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            StringBuilder path = new StringBuilder(512);
            int size = GetFinalPathNameByHandle(directoryHandle.DangerousGetHandle(), path, path.Capacity, 0);
            if (size < 0) throw new Win32Exception(Marshal.GetLastWin32Error()); // The remarks section of GetFinalPathNameByHandle mentions the return being prefixed with "\\?\" // More information about "\\?\" here -> http://msdn.microsoft.com/en-us/library/aa365247(v=VS.85).aspx
            if (path[0] == '\\' && path[1] == '\\' && path[2] == '?' && path[3] == '\\') return path.ToString().Substring(4);
            else return path.ToString();
        }
'@

    $getMemberParam = @{
        Name = "SymbolicLinkGet"
        Namespace = "GraniResource"
        UsingNameSpace   = "System.Text", "Microsoft.Win32.SafeHandles", "System.ComponentModel"
        MemberDefinition = $GetSymLink
        ErrorAction = "SilentlyContinue"
        PassThru = $true
    }
    $SymbolicLinkGet = Add-Type @getMemberParam | where Name -eq $getMemberParam.Name | %{$_ -as [Type]}

    # SetSymbolicLink Class
    $SetSymLink = @'
        internal static class Win32
        {
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.I1)]
            public static extern bool CreateSymbolicLink(string lpSymlinkFileName, string lpTargetFileName, SymLinkFlag dwFlags);
 
            internal enum SymLinkFlag
            {
                File = 0,
                Directory = 1
            }
        }
        public static void CreateSymLink(string name, string target, bool isDirectory = false)
        {
            if (!Win32.CreateSymbolicLink(name, target, isDirectory ? Win32.SymLinkFlag.Directory : Win32.SymLinkFlag.File))
            {
                throw new System.ComponentModel.Win32Exception();
            }
        }
'@
    $setMemberParam = @{
        Name = "SymbolicLinkSet"
        Namespace = "GraniResource"
        MemberDefinition = $SetSymLink
        ErrorAction = "SilentlyContinue"
        PassThru = $true
    }
    $SymbolicLinkSet = Add-Type @setMemberParam | where Name -eq $setMemberParam.Name | %{$_ -as [Type]}
}

. Initialize

#endregion

#region Message Definition

$verboseMessages = Data {
    ConvertFrom-StringData -StringData @"
        CreateSymbolicLink = DestinationPath : '{0}',  SourcePath : '{1}', IsDirectory : '{2}'
        RemovingDestinationPath = Removing reparse point (Symbolic Link) '{0}'.
"@
}

$debugMessages = Data {
    ConvertFrom-StringData -StringData @"
        SourceAttributeDetectReparsePoint = Attribute detected as ReparsePoint. : {0}
        SourceAttributeNotDetectReparsePoint = Attribute detected as NOT ReparsePoint. : {0}
        SourceDirectoryDetected = Input object : '{0}' detected as Directory.
        SourceFileDetected = Input object : '{0}' detected as File.
        DestinationFileAttribute = Attribute detected as File Archive. : {0}
        DestinationNotFileAttribute = Attribute detected as NOT File Archive. : {0}
        DestinationDirectoryAttribute = Attribute detected as Directory. : {0}
        DestinationNotDirectoryAttribute = Attribute detected as NOT Directory. : {0}
        DestinationDetectedAsFile = Destination '{0}' detected as File. Checking reparse point (Symbolic Link) or not.
        DestinationDetectedAsDirectory = Destination '{0}' detected as File. Checking reparse point (Symbolic Link) or not.
        DestinationNotFound = Destination '{0}' not found.
        DestinationNotReparsePoint = Destination was not reparse point (Symbolic Link).
        DestinationReparsePoint = Destination detected as reparse point (Symbolic Link).
        DestinationSourcePathDesired = DEstination '{0}' detected as reparse point (Symbolic Link), and SourcePath desired.
        DestinationSourcePathNotDesired = DEstination '{0}' detected as reparse point (Symbolic Link), but SourcePath not desired.
"@
}

$errorMessages = Data {
    ConvertFrom-StringData -StringData @"
"@
}

#endregion

#region *-TargetResource

function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]$DestinationPath,

        [parameter(Mandatory = $true)]
        [System.String]$SourcePath,

        [parameter(Mandatory = $true)]
        [ValidateSet("Present","Absent")]
        [System.String]$Ensure
    )

    $returnValue = @{
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
    }

    try
    {
        if ($target = IsFile -Path $DestinationPath)
        {
            Write-Debug -Message ($debugMessages.DestinationDetectedAsFile -f $DestinationPath)
            if (IsFileReparsePoint -Path $target.FullName)
            {
                Write-Debug -Message $debugMessages.DestinationReparsePoint
                $symTarget = $SymbolicLinkGet::GetSymbolicLinkTarget($target.FullName)
                if (Test-Path $SourcePath)
                {
                    Add-Member -InputObject $target -MemberType NoteProperty -Name SymbolicPath -Value $symTarget -Force
                }
            }
        }
        elseif ($target = IsDirectory -Path $DestinationPath)
        {
            Write-Debug -Message ($debugMessages.DestinationDetectedAsDirectory -f $DestinationPath)
            if (IsDirectoryReparsePoint -Path $target.FullName)
            {
                Write-Debug -Message $debugMessages.DestinationReparsePoint
                $symTarget = $SymbolicLinkGet::GetSymbolicLinkTarget($target.FullName)
                if (Test-Path $SourcePath)
                {
                    Add-Member -InputObject $target -MemberType NoteProperty -Name SymbolicPath -Value $symTarget -Force
                }
            }
        }

        if ([string]::IsNullOrEmpty($symTarget))
        {
            Write-Debug -Message ($debugMessages.DestinationNotFound -f $DestinationPath)
            $returnValue.Ensure = [EnsureType]::Absent
        }
        elseif ($symTarget -eq $SourcePath)
        {
            Write-Debug -Message ($debugMessages.DestinationSourcePathDesired -f $DestinationPath)
            $returnValue.Ensure = [EnsureType]::Present
        }
        else
        {
            Write-Debug -Message ($debugMessages.DestinationSourcePathNotDesired -f $DestinationPath)
            $returnValue.Ensure = [EnsureType]::Absent
        }
    }
    catch
    {
        $returnValue.Ensure = [EnsureType]::Absent
        Write-Verbose $_
    }

    return $returnValue
}


function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]$DestinationPath,

        [parameter(Mandatory = $true)]
        [System.String]$SourcePath,

        [parameter(Mandatory = $true)]
        [ValidateSet("Present","Absent")]
        [System.String]$Ensure
    )

    # Absent
    if ($Ensure -eq [EnsureType]::Absent.ToString())
    {
        Write-Verbose -Message ($verboseMessages.RemovingDestinationPath -f $DestinationPath)        
        RemoveSymbolicLink -Path $DestinationPath
        return;
    }

    # Present
    if ($file = IsFile -Path $SourcePath)
    {
        # Check File Type
        if (IsFileAttribute -Path $file)
        {
            Write-Verbose ($verboseMessages.CreateSymbolicLink -f $DestinationPath, $file.fullname, $false)
            $SymbolicLinkSet::CreateSymLink($DestinationPath, $file.fullname, $false)
        }
    }
    elseif ($directory = IsDirectory -Path $SourcePath)
    {
        # Check Directory Type
        if (IsDirectoryAttribute -Path $directory)
        {
            Write-Verbose ($verboseMessages.CreateSymbolicLink -f $DestinationPath, $directory.fullname, $false)
            $SymbolicLinkSet::CreateSymLink($DestinationPath, $directory.fullname, $true)
        }
    }
}


function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]$DestinationPath,

        [parameter(Mandatory = $true)]
        [System.String]$SourcePath,

        [parameter(Mandatory = $true)]
        [ValidateSet("Present","Absent")]
        [System.String]$Ensure
    )
    return (Get-TargetResource -DestinationPath $DestinationPath -SourcePath $SourcePath -Ensure $Ensure).Ensure -eq $Ensure
}

#endregion

#region Get helper

function IsFile ([string]$Path)
{
    if ([System.IO.File]::Exists($Path))
    {
        Write-Debug ($debugMessages.SourceFileDetected -f $Path)
        return [System.IO.FileInfo]($Path)
    }
}

function IsDirectory ([string]$Path)
{
    if ([System.IO.Directory]::Exists($Path))
    {
        Write-Debug ($debugMessages.SourceDirectoryDetected -f $Path)
        return [System.IO.DirectoryInfo] ($Path)
    }
}

function IsFileReparsePoint ([System.IO.FileInfo]$Path)
{
    $fileAttributes = [System.IO.FileAttributes]::Archive, [System.IO.FileAttributes]::ReparsePoint -join ', '
    $attribute = [System.IO.File]::GetAttributes($Path)
    $result = $attribute -eq $fileAttributes
    if ($result)
    {
        Write-Debug ($debugMessages.SourceAttributeDetectReparsePoint -f $attribute)
        return $result
    }
    else
    {
        Write-Debug ($debugMessages.SourceAttributeNotDetectReparsePoint -f $attribute)
        return $result
    }
}

function IsDirectoryReparsePoint ([System.IO.DirectoryInfo]$Path)
{
    $directoryAttributes = [System.IO.FileAttributes]::Directory, [System.IO.FileAttributes]::ReparsePoint -join ', '
    $result = $Path.Attributes -eq $directoryAttributes
    if ($result)
    {
        Write-Debug ($debugMessages.SourceAttributeDetectReparsePoint -f $Path.Attributes)
        return $result
    }
    else
    {
        Write-Debug ($debugMessages.SourceAttributeNotDetectReparsePoint -f $Path.Attributes)
        return $result
    }
}

#endregion

#region Remove helper

function RemoveSymbolicLink
{
    [OutputType([Void])]
    [cmdletBinding()]
    param
    (
        [parameter(Mandatory = 1, Position  = 0, ValueFromPipeline =1, ValueFromPipelineByPropertyName = 1)]
        [Alias('FullName')]
        [String]$Path
    )
    
    function RemoveFileReparsePoint ([System.IO.FileInfo]$Path)
    {
        [System.IO.File]::Delete($Path.FullName)
    }
        
    function RemoveDirectoryReparsePoint ([System.IO.DirectoryInfo]$Path)
    {
        [System.IO.Directory]::Delete($Path.FullName)
    }

    try
    {
        if ($file = IsFile -Path $Path)
        {
            if (IsFileReparsePoint -Path $file)
            {
                RemoveFileReparsePoint -Path $file
            }
        }
        elseif ($directory = IsDirectory -Path $Path)
        {
            if (IsDirectoryReparsePoint -Path $directory)
            {
                RemoveDirectoryReparsePoint -Path $directory
            }
        }
    }
    catch
    {
        throw $_
    }
}

#endregion

#region Set helper

function IsFileAttribute ([System.IO.FileInfo]$Path)
{
    $fileAttributes = [System.IO.FileAttributes]::Archive
    $attribute = [System.IO.File]::GetAttributes($Path.fullname)
    $result = $attribute -eq $fileAttributes
    if ($result)
    {
        Write-Debug ($debugMessages.DestinationFileAttribute -f $attribute)
    }
    else
    {
        Write-Debug ($debugMessages.DestinationNotFileAttribute-f $attribute)
    }
    return $result
}

function IsDirectoryAttribute ([System.IO.DirectoryInfo]$Path)
{
    $directoryAttributes = [System.IO.FileAttributes]::Directory
    $result = $Path.Attributes -eq $directoryAttributes
    if ($result)
    {
        Write-Debug ($debugMessages.DestinationDirectoryAttribute -f $attribute)
    }
    else
    {
        Write-Debug ($debugMessages.DestinationNotDirectoryAttribute -f $attribute)
    }
    return $result
}

#endregion

Export-ModuleMember -Function *-TargetResource
