/*
 * Synthetic 4D engine boundary for ownership regressions.
 *
 * Compiles the real plugin entry point (4DPlugin-VersyPDF.cpp, included
 * below) and links the real support/4DPlugin-JSON.cpp, C_TEXT.cpp,
 * C_BLOB.cpp, C_LONGINT.cpp and the bundled, unmodified 4D Plugin API
 * (4DPluginAPI.c). Only gCall4D is replaced, and VersyPDF is stubbed: no PDF
 * is parsed and nothing is signed. The "certificate" passed to the stub is
 * a synthetic byte string; no key, certificate or keychain is ever touched.
 *
 * Every engine resource (Unistrings, pictures, objects/collections, handles)
 * is a real heap block tracked in a live set, so leaks are detected exactly
 * and a dispose of something the engine no longer owns (double free) is
 * reported by name instead of being freed a second time.
 *
 * Engine semantics modelled (per the SDK contract):
 *  - PA_CreateVariable(eVK_Unistring/eVK_Picture) allocates an empty value.
 *  - PA_GetStringVariable returns a view borrowed from the variable.
 *  - PA_SetObjectProperty deep-copies strings and pictures and retains
 *    objects/collections; the caller still owns its variable.
 *  - PA_GetObjectProperty returns an owned copy (or a retained
 *    object/collection) that must be cleared; on error the result is left
 *    uninitialised (poisoned here, see g_fail_key) and must not be cleared.
 *  - PA_ExecuteCommandByID returns an owned result (New Object,
 *    JSON Stringify); on error (g_fail_1217) the result must not be cleared.
 */

/* Resolved through -I <source-root>, so the same harness tests baseline and fixed trees. */
#include "4DPlugin-VersyPDF.cpp"

#include "PrivateTypes.h"
#include "EntryPoints.h"

#include <map>
#include <set>
#include <string>
#include <vector>

extern "C" Call4DProcPtr gCall4D;

namespace {

typedef std::basic_string<PA_Unichar> u16;

struct Obj {
    int rc;
    bool coll;
    std::map<u16, PA_Variable> props;
};

struct Handle { char *data; size_t size; };

std::set<void *> g_strings;
std::set<void *> g_pictures;
std::set<Obj *> g_objects;
std::set<void *> g_handles;
std::vector<std::string> g_violations;

/* A failed PA_GetObjectProperty (g_fail_key) or JSON Stringify (g_fail_1217)
   sets eb.fError and leaves the result uninitialised. The poison is readable
   (tests fail by assertion, not by crashing) but never engine-owned, so
   reading or clearing it is counted. */
std::string g_fail_key;
bool g_fail_1217 = false;
const char kPoisonMark = 0x5A;
int g_poison_clears = 0;
PA_Unichar kPoisonBuf[] = { 'B', 'A', 'D', '!', 0 };
PA_Unichar *const kPoison = kPoisonBuf;

void violation(const std::string &what) {
    fprintf(stderr, "  ENGINE CONTRACT: %s\n", what.c_str());
    g_violations.push_back(what);
}

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "HARNESS ERROR: %s\n", msg);
    fflush(stderr);
    abort();
}

std::string narrow(const u16 &s) { std::string r; for(PA_Unichar c : s) r.push_back((char)c); return r; }
u16 widen(const std::string &s) { u16 r; for(char c : s) r.push_back((PA_Unichar)(unsigned char)c); return r; }

PA_Unistring new_string(const PA_Unichar *src, size_t len) {
    PA_Unichar *buf = (PA_Unichar *)malloc((len + 1) * sizeof(PA_Unichar));
    if(len) memcpy(buf, src, len * sizeof(PA_Unichar));
    buf[len] = 0;
    g_strings.insert(buf);
    PA_Unistring s;
    s.fLength = (PA_long32)len;
    s.fString = buf;
    s.fReserved1 = 0;
    s.fReserved2 = 0;
    return s;
}

void free_string(PA_Unistring *s) {
    if(!s->fString) return;
    if(s->fString == kPoison) {
        g_poison_clears++;
        fprintf(stderr, "  cleared an uninitialised result of a failed engine call\n");
    } else if(!g_strings.erase(s->fString)) {
        violation("double_dispose_string");
    } else {
        free(s->fString);
    }
    s->fString = 0;
    s->fLength = 0;
}

void *new_picture() {
    void *p = malloc(16);
    g_pictures.insert(p);
    return p;
}

void free_picture(void *p) {
    if(!p) return;
    if(!g_pictures.erase(p)) { violation("double_dispose_picture"); return; }
    free(p);
}

Handle *new_handle(size_t size) {
    Handle *h = (Handle *)malloc(sizeof(Handle));
    h->size = size;
    h->data = (char *)malloc(size ? size : 1);
    g_handles.insert(h);
    return h;
}

void free_handle(Handle *h) {
    if(!h) return;
    if(!g_handles.erase(h)) { violation("double_dispose_handle"); return; }
    free(h->data);
    free(h);
}

Handle *live_handle(void *p) {
    if(!g_handles.count(p)) die("used an unknown handle");
    return (Handle *)p;
}

void release_object(Obj *o);

void clear_var(PA_Variable *v) {
    if(v->fFiller == kPoisonMark) {
        g_poison_clears++;
        fprintf(stderr, "  cleared an uninitialised result of a failed engine call\n");
        v->fType = eVK_Undefined;
        v->fFiller = 0;
        return;
    }
    switch(v->fType) {
        case eVK_Unistring: free_string(&v->uValue.fString); break;
        case eVK_Picture: free_picture(v->uValue.fPicture); break;
        case eVK_Blob: free_handle((Handle *)v->uValue.fBlob.fHandle); break;
        case eVK_Object: if(v->uValue.fObject) release_object((Obj *)v->uValue.fObject); break;
        case eVK_Collection: if(v->uValue.fCollection) release_object((Obj *)v->uValue.fCollection); break;
        default: break;
    }
    v->fType = eVK_Undefined;
}

Obj *live(void *p) {
    if(!g_objects.count((Obj *)p)) die("used a dead object/collection");
    return (Obj *)p;
}

PA_Variable undefined_var() { PA_Variable v; memset(&v, 0, sizeof(v)); v.fType = eVK_Undefined; return v; }

PA_Variable copy_var(const PA_Variable &src) {
    PA_Variable dst = src;
    switch(src.fType) {
        case eVK_Unistring:
            dst.uValue.fString = new_string(src.uValue.fString.fString, src.uValue.fString.fLength);
            break;
        case eVK_Picture:
            if(!g_pictures.count(PA_Picture(src.uValue.fPicture))) die("stored a dead picture");
            dst.uValue.fPicture = new_picture();
            break;
        case eVK_Object:
            if(src.uValue.fObject) live(src.uValue.fObject)->rc++;
            break;
        case eVK_Collection:
            if(src.uValue.fCollection) live(src.uValue.fCollection)->rc++;
            break;
        default: break;
    }
    return dst;
}

Obj *new_object(bool coll = false) {
    Obj *o = new Obj();
    o->rc = 1;
    o->coll = coll;
    g_objects.insert(o);
    return o;
}

void release_object(Obj *o) {
    if(!g_objects.count(o)) { violation("double_release_object"); return; }
    if(--o->rc == 0) {
        for(auto &kv : o->props) clear_var(&kv.second);
        g_objects.erase(o);
        delete o;
    }
}

u16 key_of(const PA_Unistring &k) { return u16(k.fString, k.fLength); }

PA_Variable object_result(Obj *o) {
    PA_Variable v = undefined_var();
    v.fType = o->coll ? eVK_Collection : eVK_Object;
    if(o->coll) v.uValue.fCollection = (PA_CollectionRef)o; else v.uValue.fObject = (PA_ObjectRef)o;
    return v;
}

void execute_command(EngineBlock *eb) {
    PA_Variable **params = (PA_Variable **)eb->fPtr1;
    PA_Variable *ret = (PA_Variable *)eb->fPtr2;
    switch(eb->fParam1) {
        case 1231: { /* OB Is defined */
            Obj *o = live(params[0]->uValue.fObject);
            ret->fType = eVK_Boolean;
            ret->uValue.fBoolean = o->props.count(key_of(params[1]->uValue.fString)) ? 1 : 0;
            break;
        }
        case 1471: *ret = object_result(new_object(false)); break; /* New Object */
        case 1217: { /* JSON Stringify */
            if(eb->fParam2 != 1 || params[0]->fType != eVK_Object) die("unexpected JSON Stringify parameters");
            live(params[0]->uValue.fObject);
            if(g_fail_1217) {
                *ret = undefined_var();
                ret->fFiller = kPoisonMark;
                ret->fType = eVK_Unistring;
                ret->uValue.fString.fString = kPoison;
                ret->uValue.fString.fLength = 4;
                eb->fError = -1;
                break;
            }
            u16 json = widen("{}");
            *ret = undefined_var();
            ret->fType = eVK_Unistring;
            ret->uValue.fString = new_string(json.c_str(), json.size());
            break;
        }
        default: {
            char msg[64];
            snprintf(msg, sizeof(msg), "unexpected PA_ExecuteCommandByID %d", (int)eb->fParam1);
            die(msg);
        }
    }
}

void engine(short selector, EngineBlock *eb) {
    switch(selector) {
        case EX_GET_INFORMATION:
            eb->fParam2 = 0x00001900; /* 4D v19 */
            break;
        case EX_CREATE_UNISTRING: {
            const PA_Unichar *src = (const PA_Unichar *)eb->fHandle;
            size_t len = 0;
            while(src[len]) len++;
            eb->fUniString1 = new_string(src, len);
            break;
        }
        case EX_DISPOSE_UNISTRING:
            free_string(&eb->fUniString1);
            break;
        case EX_VARIABLE_TO_STRING: {
            PA_Variable *v = (PA_Variable *)eb->fHandle;
            if(v->fType == eVK_Unistring) eb->fUniString1 = v->uValue.fString; /* borrowed */
            break;
        }
        case EX_CREATE_PICTURE:
            eb->fPicture = new_picture();
            break;
        case EX_DISPOSE_PICTURE:
            free_picture(eb->fPicture);
            break;
        case EX_CLEAR_VARIABLE:
            clear_var((PA_Variable *)eb->fPtr1);
            break;
        case EX_YIELD_ABSOLUTE:
            break;
        case EX_SET_OBJ_VALUE: {
            Obj *o = live(eb->fPtr1);
            if(eb->fShort == eVK_Collection) die("collection set not modelled");
            PA_Variable value = copy_var(*(PA_Variable *)eb->fPtr2);
            u16 k = key_of(eb->fUniString1);
            auto it = o->props.find(k);
            if(it != o->props.end()) clear_var(&it->second);
            o->props[k] = value;
            break;
        }
        case EX_GET_OBJ_VALUE: {
            Obj *o = live(eb->fPtr1);
            PA_Variable *out = (PA_Variable *)eb->fPtr2;
            if(eb->fShort == eVK_Collection) die("collection get not modelled");
            u16 k = key_of(eb->fUniString1);
            if(!g_fail_key.empty() && narrow(k) == g_fail_key) {
                *out = undefined_var();
                out->fFiller = kPoisonMark;
                out->fType = eVK_Unistring;
                out->uValue.fString.fString = kPoison;
                out->uValue.fString.fLength = 4;
                eb->fError = -1;
                break;
            }
            auto it = o->props.find(k);
            *out = it == o->props.end() ? undefined_var() : copy_var(it->second);
            break;
        }
        case EX_EXECUTE_COMMAND_BY_ID:
            execute_command(eb);
            break;
        case EX_HANDLE_MANAGER: {
            switch(eb->fParam1) {
                case 1: eb->fHandle = (PA_Handle)new_handle((size_t)eb->fParam2); break;
                case 2: free_handle((Handle *)eb->fHandle); break;
                case 4: eb->fParam2 = (PA_long32)live_handle(eb->fHandle)->size; break;
                case 5: eb->fParam3 = (sLONG_PTR)live_handle(eb->fHandle)->data; break;
                case 6: live_handle(eb->fHandle); break;
                default: die("unexpected handle manager op");
            }
            break;
        }
        default: {
            char msg[64];
            snprintf(msg, sizeof(msg), "unmodelled engine selector %d", selector);
            die(msg);
        }
    }
}

/* ---------- VersyPDF stub (no parsing, no signing, no key material) ---------- */

struct Lib { std::vector<jmp_buf *> frames; ppInt32 last; };
struct Doc { Lib *lib; std::string bytes; };
struct Stream { std::string bytes; ppUns32 pos; };

int g_open_libs = 0, g_open_docs = 0, g_open_streams = 0;
bool g_sign_fails = false;
std::string g_signed_name, g_signed_reason, g_signed_password, g_signed_cert;
const ppUns32 kSignError = 0x0BADC0DE;

} // namespace

extern "C" {
PDFLibHandle InitPDFLibrary(char *, char *) { g_open_libs++; return (PDFLibHandle)new Lib{{}, 0}; }
void DonePDFLibrary(PDFLibHandle *lib) {
    Lib *l = (Lib *)*lib;
    if(!l->frames.empty()) die("exception frames left on DonePDFLibrary");
    delete l;
    *lib = NULL;
    g_open_libs--;
}
PDFjmp_buf *PPPushExceptionBuffer(PDFLibHandle lib) {
    jmp_buf *b = (jmp_buf *)malloc(sizeof(jmp_buf));
    ((Lib *)lib)->frames.push_back(b);
    return (PDFjmp_buf *)b;
}
void PPPopExceptionBuffer(PDFLibHandle lib) {
    Lib *l = (Lib *)lib;
    if(l->frames.empty()) die("pop of an empty exception stack");
    free(l->frames.back());
    l->frames.pop_back();
}
void PPCallException(PDFLibHandle lib, ppInt32 err) {
    Lib *l = (Lib *)lib;
    l->last = err;
    if(l->frames.empty()) die("raise outside PDFTRY");
    jmp_buf env;
    memcpy(&env, l->frames.back(), sizeof(jmp_buf));
    free(l->frames.back());
    l->frames.pop_back();
    longjmp(env, 1);
}
ppInt32 PPGetLastError(PDFLibHandle lib) { return ((Lib *)lib)->last; }
ppInt32 VSGetErrorStr(ppUns32 err, char *buf) { return snprintf(buf, 0x100, "stub error %u", (unsigned)err); }
PDFDocHandle PDFDocLoadFromBuffer(PDFLibHandle lib, void *buf, ppInt32 len) {
    g_open_docs++;
    return (PDFDocHandle)new Doc{(Lib *)lib, std::string((const char *)buf, (size_t)len)};
}
void PDFDocAppendSignatureFromBuffer(PDFDocHandle doc, void *buf, ppUns32 len, char *name, char *reason, ppBool, char *password) {
    Doc *d = (Doc *)doc;
    g_signed_cert.assign((const char *)buf, len);
    g_signed_name = name; g_signed_reason = reason; g_signed_password = password;
    if(g_sign_fails) PPCallException((PDFLibHandle)d->lib, (ppInt32)kSignError);
    d->bytes += "%SYNTHETIC-SIGNATURE";
}
void PDFDocClose(PDFDocHandle doc) { delete (Doc *)doc; g_open_docs--; }
PDFStreamHandle ULStreamMemNew(PDFLibHandle, ppUns32) { g_open_streams++; return (PDFStreamHandle)new Stream{std::string(), 0}; }
void PDFDocSaveToStream(PDFDocHandle doc, PDFStreamHandle s) { ((Stream *)s)->bytes = ((Doc *)doc)->bytes; }
ppUns32 ULStreamGetSize(PDFStreamHandle s) { return (ppUns32)((Stream *)s)->bytes.size(); }
ppUns32 ULStreamSetPosition(PDFStreamHandle s, ppUns32 p) { ((Stream *)s)->pos = p; return p; }
ppUns32 ULStreamReadBuffer(PDFStreamHandle s, void *buf, ppUns32 n) {
    Stream *st = (Stream *)s;
    ppUns32 avail = (ppUns32)st->bytes.size() - st->pos;
    if(n > avail) n = avail;
    memcpy(buf, st->bytes.data() + st->pos, n);
    st->pos += n;
    return n;
}
void ULStreamClose(PDFStreamHandle s) { delete (Stream *)s; g_open_streams--; }
}

namespace {

/* ---------- test helpers ---------- */

PA_Unistring U(const char *ascii) {
    u16 s = widen(ascii);
    return new_string(s.c_str(), s.size());
}

void put(Obj *o, const char *key, PA_Variable v) {
    PA_Unistring k = U(key);
    PA_SetObjectProperty((PA_ObjectRef)o, &k, v);
    PA_DisposeUnistring(&k);
}

void put_text(Obj *o, const char *key, const char *value) {
    PA_Variable v = undefined_var();
    PA_Unistring u = U(value);
    PA_SetStringVariable(&v, &u);
    put(o, key, v);
    PA_ClearVariable(&v);
}

void put_real(Obj *o, const char *key, double d) {
    PA_Variable v = undefined_var();
    PA_SetRealVariable(&v, d);
    put(o, key, v);
}

Obj *put_child(Obj *o, const char *key, bool coll) {
    Obj *c = new_object(coll);
    PA_Variable v = object_result(c);
    put(o, key, v);
    PA_ClearVariable(&v);
    return c;
}

bool check(bool ok, const char *what) {
    if(!ok) fprintf(stderr, "  check failed: %s\n", what);
    return ok;
}

bool no_leaks() {
    bool ok = true;
    for(void *p : g_strings) {
        fprintf(stderr, "  LEAK: engine string \"%s\"\n", narrow(u16((PA_Unichar *)p)).c_str());
        ok = false;
    }
    if(!g_pictures.empty()) { fprintf(stderr, "  LEAK: %zu engine picture(s)\n", g_pictures.size()); ok = false; }
    if(!g_objects.empty()) { fprintf(stderr, "  LEAK: %zu engine object(s)/collection(s)\n", g_objects.size()); ok = false; }
    if(!g_handles.empty()) { fprintf(stderr, "  LEAK: %zu engine handle(s)\n", g_handles.size()); ok = false; }
    if(g_poison_clears) { fprintf(stderr, "  %d failed result(s) cleared\n", g_poison_clears); ok = false; }
    if(g_open_libs || g_open_docs || g_open_streams) { fprintf(stderr, "  LEAK: VersyPDF lib/doc/stream\n"); ok = false; }
    if(!g_violations.empty()) ok = false;
    return ok;
}

Handle *blob(const std::string &bytes) {
    Handle *h = new_handle(bytes.size());
    memcpy(h->data, bytes.data(), bytes.size());
    return h;
}

std::string blob_bytes(PA_Handle h) {
    Handle *b = live_handle(h);
    return std::string(b->data, b->size);
}

/* The real `SIGN PDF(&O;&O;&T;&T;&T;&L):J` entry point, with 4D-style
   parameter slots. The caller (4D) owns the BLOB slots and text params. */
struct SignCall {
    PA_Handle pdf, cert;
    PA_Unistring name, reason, password;
    PA_long32 pkcs7;
    PA_ObjectRef result;
};

void call_sign_pdf(SignCall &c) {
    void *args[6] = { &c.pdf, &c.cert, &c.name, &c.reason, &c.password, &c.pkcs7 };
    PluginBlock pb;
    pb.fParameters = (PA_Variable *)args;
    pb.fResult = &c.result;
    pb.fData = NULL;
    PluginMain(1, &pb);
}

SignCall sign_call(Handle *pdf, Handle *cert) {
    SignCall c;
    c.pdf = (PA_Handle)pdf;
    c.cert = (PA_Handle)cert;
    c.name = U("Synthetic Signer");
    c.reason = U("synthetic test");
    c.password = U("not-a-password");
    c.pkcs7 = 1;
    c.result = NULL;
    return c;
}

/* What 4D does after the call: owns the returned object and the params. */
void release_sign_call(SignCall &c) {
    if(c.result) release_object(live(c.result));
    free_handle((Handle *)c.pdf);
    free_handle((Handle *)c.cert);
    free_string(&c.name);
    free_string(&c.reason);
    free_string(&c.password);
}

bool result_is(Obj *r, bool success, double error) {
    if(!r) return check(false, "result object returned");
    auto s = r->props.find(widen("success"));
    auto e = r->props.find(widen("error"));
    auto m = r->props.find(widen("errorMessage"));
    bool ok = check(s != r->props.end() && s->second.fType == eVK_Boolean && !!s->second.uValue.fBoolean == success, "success flag");
    ok &= check(e != r->props.end() && e->second.fType == eVK_Real && e->second.uValue.fReal == error, "error code");
    ok &= check(m != r->props.end() && m->second.fType == eVK_Unistring && g_strings.count(m->second.uValue.fString.fString), "errorMessage text");
    return ok;
}

/* ---------- LIVE: SIGN PDF (controls: pass on both trees) ---------- */

bool control_cmd_sign_pdf_success() {
    Handle *pdf = blob("%PDF-1.7 synthetic");
    SignCall c = sign_call(pdf, blob("SYNTHETIC-PKCS12-BYTES"));
    call_sign_pdf(c);
    bool ok = result_is((Obj *)c.result, true, 0);
    ok &= check(!g_handles.count(pdf), "original BLOB handle disposed when replaced");
    ok &= check(blob_bytes(c.pdf) == "%PDF-1.7 synthetic%SYNTHETIC-SIGNATURE", "signed bytes returned in $1");
    ok &= check(g_signed_cert == "SYNTHETIC-PKCS12-BYTES" && g_signed_name == "Synthetic Signer"
                && g_signed_reason == "synthetic test" && g_signed_password == "not-a-password", "params passed to the stub");
    release_sign_call(c);
    return no_leaks() && ok;
}

bool control_cmd_sign_pdf_sign_error() {
    g_sign_fails = true;
    Handle *pdf = blob("%PDF-1.7 synthetic");
    SignCall c = sign_call(pdf, blob("SYNTHETIC-PKCS12-BYTES"));
    call_sign_pdf(c);
    bool ok = result_is((Obj *)c.result, false, kSignError);
    ok &= check(c.pdf == (PA_Handle)pdf && blob_bytes(c.pdf) == "%PDF-1.7 synthetic", "$1 untouched on failure");
    release_sign_call(c);
    return no_leaks() && ok;
}

bool control_cmd_sign_pdf_no_header() {
    Handle *pdf = blob("not a pdf");
    SignCall c = sign_call(pdf, blob("SYNTHETIC-PKCS12-BYTES"));
    call_sign_pdf(c);
    bool ok = result_is((Obj *)c.result, false, (double)PDFBuildErrCode(ErrCosLevel, cleNoHeaderError));
    ok &= check(c.pdf == (PA_Handle)pdf, "$1 untouched");
    ok &= check(g_signed_cert.empty(), "stub signer not reached");
    release_sign_call(c);
    return no_leaks() && ok;
}

bool control_cmd_sign_pdf_empty_blob() {
    SignCall c = sign_call(NULL, blob("SYNTHETIC-PKCS12-BYTES"));
    call_sign_pdf(c);
    bool ok = result_is((Obj *)c.result, false, (double)PDFBuildErrCode(ErrCosLevel, cleNoHeaderError));
    ok &= check(c.pdf == NULL, "$1 untouched");
    release_sign_call(c);
    return no_leaks() && ok;
}

/* ---------- DORMANT: built, no caller ---------- */

bool defect_dormant_ob_get_a_result_not_cleared() {
    Obj *o = new_object(false);
    put_text(o, "name", "value");
    CUTF8String s;
    bool r = ob_get_a((PA_ObjectRef)o, L"name", &s);
    release_object(o);
    bool ok = check(r && s == (const uint8_t *)"value", "value read");
    return no_leaks() && ok;
}

bool defect_dormant_ob_get_n_wrong_kind_not_cleared() {
    Obj *o = new_object(false);
    put_text(o, "n", "text");
    double d = ob_get_n((PA_ObjectRef)o, L"n");
    release_object(o);
    bool ok = check(d == 0.0, "wrong kind yields 0");
    return no_leaks() && ok;
}

bool defect_dormant_ob_get_b_wrong_kind_not_cleared() {
    Obj *o = new_object(false);
    put_text(o, "b", "yes");
    bool b = ob_get_b((PA_ObjectRef)o, L"b");
    release_object(o);
    bool ok = check(!b, "wrong kind yields false");
    return no_leaks() && ok;
}

/* The returned reference is borrowed from the parent: valid while the
   parent holds it, gone with the parent. */
bool defect_dormant_ob_get_c_reference_not_released() {
    Obj *o = new_object(false);
    Obj *c = put_child(o, "items", true);
    PA_CollectionRef r = ob_get_c((PA_ObjectRef)o, L"items");
    bool ok = check(r == (PA_CollectionRef)c && g_objects.count(c), "borrowed collection returned");
    release_object(o);
    return no_leaks() && ok;
}

bool defect_dormant_ob_get_o_reference_not_released() {
    Obj *o = new_object(false);
    Obj *c = put_child(o, "child", false);
    PA_ObjectRef r = ob_get_o((PA_ObjectRef)o, L"child");
    bool ok = check(r == (PA_ObjectRef)c && g_objects.count(c), "borrowed object returned");
    release_object(o);
    return no_leaks() && ok;
}

/* ---------- HARDENING ---------- */

/* On error PA_GetObjectProperty leaves its result uninitialised (no
   pre-init in the SDK): it must be neither read nor cleared. */
bool hardening_ob_get_error_result_untouched() {
    Obj *o = new_object(false);
    put_text(o, "a", "x");
    put_real(o, "n", 1.0);
    CUTF8String s;
    g_fail_key = "a";
    ob_get_a((PA_ObjectRef)o, L"a", &s);
    g_fail_key = "n";
    double d = ob_get_n((PA_ObjectRef)o, L"n");
    g_fail_key = "a";
    bool b = ob_get_b((PA_ObjectRef)o, L"a");
    PA_CollectionRef c = ob_get_c((PA_ObjectRef)o, L"a");
    PA_ObjectRef x = ob_get_o((PA_ObjectRef)o, L"a");
    g_fail_key.clear();
    release_object(o);
    bool ok = check(s.empty() && d == 0.0 && !b && !c && !x, "failed reads yield nothing");
    return no_leaks() && ok;
}

/* ob_stringify cleared the 1217 result without checking PA_GetLastError. */
bool hardening_ob_stringify_error_result_untouched() {
    Obj *o = new_object(false);
    g_fail_1217 = true;
    CUTF8String s;
    ob_stringify((PA_ObjectRef)o, &s);
    g_fail_1217 = false;
    bool ok = check(s.empty(), "failed stringify yields nothing");
    ok &= check(g_objects.count(o) && o->rc == 1, "caller's object not released");
    release_object(o);
    return no_leaks() && ok;
}

/* ---------- controls for the helpers (pass on both trees) ---------- */

bool control_dormant_ob_stringify() {
    Obj *o = new_object(false);
    CUTF8String s;
    ob_stringify((PA_ObjectRef)o, &s);
    bool ok = check(s == (const uint8_t *)"{}", "JSON read");
    ok &= check(g_objects.count(o) && o->rc == 1, "caller's object not released");
    release_object(o);
    return no_leaks() && ok;
}

bool control_ob_get_scalars() {
    Obj *o = new_object(false);
    put_real(o, "n", 2.5);
    PA_Variable v = undefined_var();
    PA_SetBooleanVariable(&v, 1);
    put(o, "b", v);
    bool ok = check(ob_is_defined((PA_ObjectRef)o, L"n") && !ob_is_defined((PA_ObjectRef)o, L"none"), "ob_is_defined");
    ok &= check(ob_get_n((PA_ObjectRef)o, L"n") == 2.5, "real read");
    ok &= check(ob_get_b((PA_ObjectRef)o, L"b"), "bool read");
    release_object(o);
    return no_leaks() && ok;
}

bool control_ob_set_helpers() {
    Obj *o = new_object(false);
    ob_set_s((PA_ObjectRef)o, "s1", "v1");
    ob_set_s((PA_ObjectRef)o, L"s2", "v2");
    ob_set_a((PA_ObjectRef)o, L"a1", L"v3");
    CUTF16String v4 = widen("v4");
    ob_set_a((PA_ObjectRef)o, L"a2", &v4);
    ob_set_n((PA_ObjectRef)o, L"n1", 1.0);
    ob_set_n((PA_ObjectRef)o, "n2", 2.0);
    ob_set_i((PA_ObjectRef)o, L"i", 3);
    ob_set_b((PA_ObjectRef)o, L"b", true);
    ob_set_0((PA_ObjectRef)o, L"z1");
    ob_set_0((PA_ObjectRef)o, "z2");
    ob_set_p((PA_ObjectRef)o, L"p", PA_CreatePicture(NULL, 0)); /* consumed */
    Obj *child = new_object(false), *coll = new_object(true);
    ob_set_o((PA_ObjectRef)o, L"o1", (PA_ObjectRef)child);
    ob_set_c((PA_ObjectRef)o, L"c", (PA_CollectionRef)coll);
    bool ok = check(o->props.size() == 13, "thirteen properties set");
    ok &= check(child->rc == 1 && coll->rc == 1, "o/c helpers transfer the caller's reference to the parent");
    release_object(o);
    return no_leaks() && ok;
}

struct Test { const char *name; bool (*fn)(); };
const Test kTests[] = {
    { "control_cmd_sign_pdf_success", control_cmd_sign_pdf_success },
    { "control_cmd_sign_pdf_sign_error", control_cmd_sign_pdf_sign_error },
    { "control_cmd_sign_pdf_no_header", control_cmd_sign_pdf_no_header },
    { "control_cmd_sign_pdf_empty_blob", control_cmd_sign_pdf_empty_blob },
    { "defect_dormant_ob_get_a_result_not_cleared", defect_dormant_ob_get_a_result_not_cleared },
    { "defect_dormant_ob_get_n_wrong_kind_not_cleared", defect_dormant_ob_get_n_wrong_kind_not_cleared },
    { "defect_dormant_ob_get_b_wrong_kind_not_cleared", defect_dormant_ob_get_b_wrong_kind_not_cleared },
    { "defect_dormant_ob_get_c_reference_not_released", defect_dormant_ob_get_c_reference_not_released },
    { "defect_dormant_ob_get_o_reference_not_released", defect_dormant_ob_get_o_reference_not_released },
    { "hardening_ob_get_error_result_untouched", hardening_ob_get_error_result_untouched },
    { "hardening_ob_stringify_error_result_untouched", hardening_ob_stringify_error_result_untouched },
    { "control_dormant_ob_stringify", control_dormant_ob_stringify },
    { "control_ob_get_scalars", control_ob_get_scalars },
    { "control_ob_set_helpers", control_ob_set_helpers },
};

} // namespace

int main(int argc, char **argv) {
    gCall4D = engine;
    if(argc == 2 && !strcmp(argv[1], "--list")) {
        for(const Test &t : kTests) printf("%s\n", t.name);
        return 0;
    }
    if(argc != 2) { fprintf(stderr, "usage: %s --list | <test>\n", argv[0]); return 2; }
    for(const Test &t : kTests) {
        if(!strcmp(argv[1], t.name)) {
            bool ok = t.fn();
            printf("%s: %s\n", t.name, ok ? "PASS" : "FAIL");
            return ok ? 0 : 1;
        }
    }
    fprintf(stderr, "unknown test %s\n", argv[1]);
    return 2;
}
