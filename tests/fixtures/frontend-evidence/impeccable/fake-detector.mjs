const argv = process.argv.slice(2);
const expectedPrefix = ["detect", "--fast", "--json"];
if (expectedPrefix.some((value, index) => argv[index] !== value) || argv.length <= expectedPrefix.length) {
  process.stderr.write("invalid detector argv\n");
  process.exitCode = 2;
} else {
  process.stdout.write(JSON.stringify({
    schemaVersion: 1,
    detector: "local-controlled-fixture",
    scope: "fixture",
    productRoutesEvaluated: false,
    findings: [],
    inspectedPaths: argv.slice(expectedPrefix.length),
  }));
}
