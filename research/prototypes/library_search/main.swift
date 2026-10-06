let parts = Set(CommandLine.arguments.dropFirst())
if parts.isEmpty || parts.contains("1") {
    partOne()
}

if parts.isEmpty || parts.contains("2") {
    partTwo()
}

if parts.isEmpty || parts.contains("3") {
    partThree()
}
