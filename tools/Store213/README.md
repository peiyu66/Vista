# 213 source and diagnostic regression checks

From the repository root:

```sh
python3 tools/Store213/verify.py
python3 tools/Store213/verify_scope.py
python3 tools/Store213/test_input_log.py
python3 tools/Store213/test_all_writers.py
python3 tools/Store211/check_notices.py
python3 tools/Store208/check_resources.py
```

The runtime checks require macOS and Xcode and write isolated results beneath `.build/store213`. They execute the actual shared writer and copied recorder, checking that the copied recorder matches the embedded App source before execution. Diagnostic must create files; Release must not create diagnostic files or change an existing old log. These tests do not simulate physical pinches or eye focus and are not a complete visionOS runtime test.

Use `VistaBrowser.xcodeproj`, scheme `VistaBrowser`, configuration `Release` for the shipping archive or `Diagnostic` for the optimized logging build. Both use the same source. Build213 retains the36pt target inside44pt layout as requested; no claim of improved acquisition. Native artifacts are verified against the accepted211 inputs. Distribution signatures and device logs remain private; the baseline contains only source and artifact hashes and test summaries.
