Import-Module xDSCResourceDesigner
$property = @()
$property += New-xDscResourceProperty `
    -Name Target `
    -Type String `
    -Attribute Key
$property += New-xDscResourceProperty `
    -Name Credential `
    -Type PSCredential `
    -Attribute Write
$property += New-xDscResourceProperty `
    -Name Ensure `
    -Type String `
    -Attribute Required `
    -ValueMap Present, Absent `
    -Values Present, Absent `
    -Description "Ensure Target entry is Present or Absent."
New-xDscResource -Name Grani_CredentialManager -Property $property -Path .\ -ModuleName GraniResource -FriendlyName cCredentialManager -Force