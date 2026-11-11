# 4d-plugin-sign-pdf-versy

### Platform

| carbon | cocoa | win64 |
|:------:|:-----:|:---------:|
||<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img width="32" height="32" src="https://user-images.githubusercontent.com/1725068/73986501-15964580-4981-11ea-9ac1-73c5cee50aae.png"> <img src="https://user-images.githubusercontent.com/1725068/73987971-db2ea780-4984-11ea-8ada-e25fb9c3cf4e.png" width="32" height="32" />

Adds an invisible digital signature to a PDF document held in a `BLOB`, using a PKCS#12 (`.pfx`/`.p12`) certificate and private key, also passed as a `BLOB`. The signing is done by the [sybrexsys/VersyPDF](https://github.com/sybrexsys/VersyPDF) library, statically linked into the plugin (no other software is needed at run time). The signed document replaces the content of the PDF `BLOB` variable you pass; the command returns an `Object` that tells you whether it worked and, if not, why.

| Command | Returns | Purpose |
|---|---|---|
| [SIGN PDF](#sign-pdf) | `Object` | Sign a PDF `BLOB` in place with a PKCS#12 identity |

**Platforms:** macOS, Windows (64-bit)

---

## Requirements & platform notes

- **All six parameters are mandatory.** The first parameter is both input and output: on success it is overwritten with the signed PDF.
- **Failure is reported in the result object, not as a 4D error.** Always test `$status.success` before using the `BLOB`. When signing fails, the PDF `BLOB` is left unchanged.
- **Only SHA-1 signatures are produced** (`adbe.pkcs7.sha1` and `adbe.x509.rsa_sha1`, see [Signature types](#signature-types)). Current PDF readers may mark SHA-1 signatures as weak or not trust them; check with the reader your recipients use.
- **The PDF must start with `%PDF-1.`** (PDF 1.x, no leading bytes). Anything else is rejected with a "No Header" error. Encrypted (password-protected) PDFs can't be signed.
- **A damaged or truncated PDF can crash 4D.** The input check above only catches empty and non-PDF `BLOB`s. VersyPDF itself crashes on some malformed files that do start with `%PDF-1.` (for example a truncated download), so pass only complete PDF files.
- **The PKCS#12 file must contain an RSA private key and its certificate.** The signer name shown by PDF readers is the certificate's common name (CN), not a parameter of the command.
- The command is declared thread-safe in the plugin manifest, so 4D allows it in preemptive processes.
- VersyPDF is licensed under the GNU AGPL v3; the licence files are in the plugin's `Contents/Resources` folder.

---

## SIGN PDF

### Syntax

```
SIGN PDF ( pdf ; pfx ; name ; reason ; password ; type ) -> status
```

| Parameter | Type | Description |
|---|---|---|
| `pdf` | `BLOB` | In: the PDF document to sign. Out: the signed PDF (only when `status.success` is `True`). |
| `pfx` | `BLOB` | PKCS#12 (`.pfx`/`.p12`) data holding the RSA private key and certificate. |
| `name` | `Text` | Name of the signature field created in the document (the field's `/T` entry). |
| `reason` | `Text` | Reason for signing, stored in the signature (`/Reason`). |
| `password` | `Text` | Password of the PKCS#12 data. |
| `type` | `Longint` | Signature type: `Adobe_PPKLite_adbe_x509_rsa_sha1` (0) or `Adobe_PPKMS_adbe_pkcs7_sha1` (1). |
| Result | `Object` | Status object, see below. |

#### Status object

| Property | Type | Description |
|---|---|---|
| `success` | `Boolean` | `True` when the signed PDF was written into `pdf`. |
| `error` | `Longint` | VersyPDF error code of the last error; `0` when there was none. |
| `errorMessage` | `Text` | Text of that error, as `"<level> ( <error> )"`, e.g. `"Signature Level ( Bad Password )"` or `"Cos Object Level ( No Header )"`. |

`error` and `errorMessage` are present whenever the VersyPDF library could be initialised, which is normally always.

#### Signature types

The constants are in the `PDF Signature Type` theme:

| Constant | Value | `/Filter` | `/SubFilter` |
|---|---|---|---|
| `Adobe_PPKLite_adbe_x509_rsa_sha1` | 0 | `Adobe.PPKLite` | `adbe.x509.rsa_sha1` |
| `Adobe_PPKMS_adbe_pkcs7_sha1` | 1 | `Adobe.PPKMS` | `adbe.pkcs7.sha1` |

Pass one of these two constants; other values are not supported.

### Description

`SIGN PDF` loads the document from `pdf`, adds a signature field named `name` on the first page, signs the document with the key and certificate from `pfx`, and saves the whole document back into `pdf`. The signature has no visible appearance (its rectangle is `0 0 0 0`). The signing time is the computer's local time with its UTC offset.

`name`, `reason` and `password` are passed to the library as UTF-8 bytes. `reason` is stored as a plain PDF string, so non-ASCII text is likely to display incorrectly in PDF readers (inferred from the library source, not tested); keep it ASCII.

The document is saved as a new file, not as an incremental update. If the input already contains signatures, they are likely to be invalidated (inferred, not tested).

`success` is `False`, and `pdf` is unchanged, when:

- `pdf` is empty or does not start with `%PDF-1.` (`"Cos Object Level ( No Header )"`);
- the PDF can't be parsed or is encrypted;
- the `pfx` data can't be read or `password` is wrong (`"Signature Level ( Bad Password )"`);
- saving the signed document fails.

Earlier versions of the plugin (1.0.0) leaked memory on every call, could stop the 4D application when given an empty or non-PDF `BLOB`, and could leave the calling process waiting for a result if an unexpected C++ exception occurred. These are fixed in the version that includes this documentation.

### Example

From the plugin's own test method (`TEST_1.4dm`):

```4d
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
```

Reporting a failure instead of ignoring it:

```4d
$status:=SIGN PDF ($PDF;$PFX;"Signature1";"Approved";$password;Adobe_PPKLite_adbe_x509_rsa_sha1)

If ($status.success)
	BLOB TO DOCUMENT($path;$PDF)
Else 
	ALERT("Signing failed: "+$status.errorMessage+" ("+String($status.error)+")")
End if 
```

Note that the openssl commands in the test method's comments create a self-signed certificate: PDF readers will show the signature as made by an unknown identity until that certificate is trusted.

---

## Error handling & troubleshooting

- **Check `success`, not the `BLOB` size.** On failure the `BLOB` still holds the original, unsigned PDF.
- **"Cos Object Level ( No Header )"**: `pdf` is empty (for example `DOCUMENT TO BLOB` read the wrong path) or is not a PDF 1.x file starting with `%PDF-1.`.
- **"Signature Level ( Bad Password )"**: the `password` does not open the `pfx` data, or the data is not PKCS#12.
- **4D quits while signing**: the PDF is damaged or truncated. VersyPDF crashes on some malformed files, and the plugin can't intercept that. Check the file in a PDF reader first.
- **Readers say the signature is weak or untrusted**: the signature uses SHA-1, and a self-signed certificate is unknown to the reader. Use a certificate from an authority your recipients trust; the SHA-1 limitation can't be changed from 4D.
- **Garbled reason text**: use ASCII characters in `reason`.

---

## Quick reference

```4d
DOCUMENT TO BLOB($pdfPath;$PDF)
DOCUMENT TO BLOB($pfxPath;$PFX)
$status:=SIGN PDF ($PDF;$PFX;"Signature1";"Approved";$password;Adobe_PPKMS_adbe_pkcs7_sha1)
If ($status.success)
	BLOB TO DOCUMENT($outPath;$PDF)
Else 
	ALERT($status.errorMessage)
End if 
```
