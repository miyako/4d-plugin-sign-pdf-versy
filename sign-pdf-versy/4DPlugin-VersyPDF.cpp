/* --------------------------------------------------------------------------------
 #
 #  4DPlugin-VersyPDF.cpp
 #	source generated by 4D Plugin Wizard
 #	Project : VersyPDF
 #	author : miyako
 #	2020/03/09
 #
 # --------------------------------------------------------------------------------*/

#include "4DPlugin-VersyPDF.h"

#pragma mark -

void PluginMain(PA_long32 selector, PA_PluginParameters params) {
    
    try
    {
        switch(selector)
        {
                // --- VersyPDF
                
            case 1 :
                SIGN_PDF(params);
                break;
                
        }
        
    }
    catch(...)
    {
        
    }
}

#pragma mark -

void setStatus(PA_ObjectRef obj, PDFLibHandle Lib){
    
    if(obj){
        
    }
    if(Lib){
        
        /* get error */
        std::vector<char> buf(0x100);
        ppUns32 e = PPGetLastError(Lib);
        VSGetErrorStr(e, &buf[0]);
        
        ob_set_n(obj, L"error", e);
        ob_set_s(obj, "errorMessage", &buf[0]);
    }
}

void SIGN_PDF(PA_PluginParameters params) {
    
    PackagePtr pParams = (PackagePtr)params->fParameters;
    
    PA_ObjectRef returnValue = PA_CreateObject();
    
    PDFDocHandle Doc = NULL;
    PDFLibHandle Lib = NULL;
    
    C_TEXT Param3;
    Param3.fromParamAtIndex(pParams, 3);
    
    C_TEXT Param4;
    Param4.fromParamAtIndex(pParams, 4);
    
    C_TEXT Param5;
    Param5.fromParamAtIndex(pParams, 5);
    
    CUTF8String name, reason, password;
    
    Param3.copyUTF8String(&name);
    Param4.copyUTF8String(&reason);
    Param5.copyUTF8String(&password);
    
    char *Name = (char *)name.c_str();
    char *Reason = (char *)reason.c_str();
    char *Password = (char *)password.c_str();
    
    C_LONGINT Param6;
    Param6.fromParamAtIndex(pParams, 6);
    
    ppBool PKCS7 = static_cast<ppBool>(Param6.getIntValue());
    
    bool success = false;
    
    Lib = InitPDFLibrary(NULL, NULL);
    
    if(Lib) {
        
        PA_Handle h1 = PA_GetBlobHandleParameter(params, 1);
        
        if(h1) {
            
            ppInt32 DocSize = static_cast<ppInt32>(PA_GetHandleSize(h1));
            
            PDFTRY(Lib){
                Doc = PDFDocLoadFromBuffer(Lib,
                                           PA_LockHandle(h1),
                                           DocSize);
            }PDFEXCEPT(Lib){
                
            }PDFTRYEND(Lib);
            
            PA_UnlockHandle(h1);
            
            if(Doc) {
                
                PA_Handle h2 = PA_GetBlobHandleParameter(params, 2);
                
                if(h2) {
                    
                    PDFTRY(Lib){
                        PDFDocAppendSignatureFromBuffer(Doc,
                                                        PA_LockHandle(h2),
                                                        static_cast<ppInt32>(PA_GetHandleSize(h2)),
                                                        Name,
                                                        Reason,
                                                        PKCS7,
                                                        Password);
                    }PDFEXCEPT(Lib){
                        
                    }PDFTRYEND(Lib);
                    
                    PA_UnlockHandle(h2);
                    
                    if(!PPGetLastError(Lib)) {
                        
                        ppInt32 size = 0;
                        
                        PDFTRY(Lib){
                            const uint8_t *bytes = (const uint8_t *)PDFDocSaveToBuffer(Doc, &size);
                            
                            C_BLOB signedPdf;
                            signedPdf.setBytes(bytes, static_cast<uint32_t>(size));
                            signedPdf.toParamAtIndex(pParams, 1);
                            success = true;
                        }PDFEXCEPT(Lib){
                            
                        }PDFTRYEND(Lib);
                        
                    }
                    
                }
                PDFDocClose(Doc);
            }
            
        }
        
        setStatus(returnValue, Lib);
        
        DonePDFLibrary(&Lib);
        
        Lib = NULL;
    }
    
    ob_set_b(returnValue, L"success", success);
    
    PA_ReturnObject(params, returnValue);
}

