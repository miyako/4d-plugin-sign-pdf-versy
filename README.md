# 4d-plugin-sign-pdf-versy
Add digital signature to PDF using [sybrexsys/VersyPDF](https://github.com/sybrexsys/VersyPDF)

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
