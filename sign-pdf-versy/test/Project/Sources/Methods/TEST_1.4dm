//%attributes = {}
$path:=Get 4D folder:C485(Current resources folder:K5:16)+"test.pdf"
DOCUMENT TO BLOB:C525($path;$PDF)

  //PFX (PKCS#12): what is this..?
  //1. Generate a private key
  //openssl genrsa -out private.pem 2048
  //2. Generate a public key
  //openssl req -x509 -new -key private.pem -out public.pem
  //3. Create PFX
  //openssl pkcs12 -export -in public.pem -inkey private.pem -out profile.pfx


$path:=Get 4D folder:C485(Current resources folder:K5:16)+"profile.pfx"
DOCUMENT TO BLOB:C525($path;$PFX)

$name:="miyako"
$password:="1234"
$reason:="I agree..."

$status:=SIGN PDF ($PDF;$PFX;$name;$reason;$password;Adobe_PPKMS_adbe_pkcs7_sha1)

If ($status.success)
	
	$path:=System folder:C487(Desktop:K41:16)+"signed_test.pdf"
	BLOB TO DOCUMENT:C526($path;$PDF)
	SHOW ON DISK:C922($path)
	
End if 

  //verify online

  //Adobe_PPKMS_adbe_pkcs7_sha1
  //https://account.ascertia.com/demos/PDFSignatureVerificationStep1