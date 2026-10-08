// Runs as the test bundle loads, before Swift Testing evaluates any test's traits (some open an
// engine): Swift itself has no code that runs at load.
void RedlampTestRunBegin(void);

__attribute__((constructor)) static void begin(void) {
    RedlampTestRunBegin();
}
