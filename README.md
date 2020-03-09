# 4d-plugin-sign-pdf-versy
Add digital signature to PDF using [sybrexsys/VersyPDF](https://github.com/sybrexsys/VersyPDF)

### Platform

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
||<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img width="32" height="32" src="https://user-images.githubusercontent.com/1725068/73986501-15964580-4981-11ea-9ac1-73c5cee50aae.png"> <img src="https://user-images.githubusercontent.com/1725068/73987971-db2ea780-4984-11ea-8ada-e25fb9c3cf4e.png" width="32" height="32" />

### Supported Signature Types

```json
[
	{
	"filter": "Adobe.PPKMS",
	"subfilter": "adbe.pkcs7.sha1"
	},
	{
	"filter": "Adobe.PPKLite",
	"subfilter": "adbe.x509.rsa_sha1"
	}
]
```

### Examples

```
$path:=Get 4D folder(Current resources folder)+"test.pdf"
DOCUMENT TO BLOB($path;$PDF)

  //PFX (PKCS#12): what is this..?
  //1. Generate a private key
  //openssl genrsa -out private.pem 2048
  //2. Generate a public key
  //openssl req -x509 -new -key private.pem -out public.pem
  //3. Create PFX
  //openssl pkcs12 -export -in public.pem -inkey private.pem -out profile.pfx


$path:=Get 4D folder(Current resources folder)+"profile.pfx"
DOCUMENT TO BLOB($path;$PFX)

$name:="miyako"
$password:="1234"
$reason:="I agree..."

$status:=SIGN PDF ($PDF;$PFX;$name;$reason;$password;Adobe_PPKMS_adbe_pkcs7_sha1)

If ($status.success)
	
	$path:=System folder(Desktop)+"signed_test.pdf"
	BLOB TO DOCUMENT($path;$PDF)
	SHOW ON DISK($path)
	
End if 

  //verify online

  //Adobe_PPKMS_adbe_pkcs7_sha1
  //https://account.ascertia.com/demos/PDFSignatureVerificationStep1
```
