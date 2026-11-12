# Ownership regressions

`run.sh <source-root> <fixed|baseline>` builds the real plugin sources (`4DPlugin-VersyPDF.cpp`, `support/4DPlugin-JSON.cpp`, `C_TEXT.cpp`, `C_BLOB.cpp`, `C_LONGINT.cpp`) and the full, unchanged bundled `4DPluginAPI.c` with ASan/UBSan. It links them against `engine_harness.cpp`, a synthetic `Call4D` boundary that tracks every engine string, picture, object and handle. Each test runs in its own process.

VersyPDF is stubbed: nothing is parsed or signed. The certificate passed to `SIGN PDF` is a synthetic byte string. No key, certificate or keychain is used.

- `control_cmd_sign_pdf_*`: the LIVE `SIGN PDF` command paths. These pass on both trees.
- `defect_dormant_*`: `ob_get_*` helpers (built, with no caller) that did not clear the owned `PA_GetObjectProperty` result.
- `hardening_*`: failed `PA_GetObjectProperty` and `JSON Stringify` (1217) results must be neither read nor cleared.

To check the baseline, run the same harness against an immutable base:

```sh
mkdir /tmp/base && git archive <base-sha> | tar -x -C /tmp/base
tests/ownership/run.sh /tmp/base baseline   # defect/hardening tests fail, controls pass
tests/ownership/run.sh . fixed              # all pass
```

Gaps: macOS only (the `VERSIONWIN` branches are not compiled), and the harness is not a real 4D runtime.
