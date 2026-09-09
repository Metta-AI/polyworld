import
  std/[os, osproc]

const
  RepositoryRoot = currentSourcePath().parentDir.parentDir
  CompilerPath = getCurrentCompilerExe()
  MacMetadata = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GotA Map Editor</string>
  <key>CFBundleDisplayName</key><string>GotA Map Editor</string>
  <key>CFBundleIdentifier</key><string>local.polyworld.gota.editor</string>
  <key>CFBundleExecutable</key><string>editor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
"""

type EditorBuildError = object of CatchableError

proc buildEditor() =
  ## Builds the standalone editor and a launchable app bundle on macOS.
  setCurrentDir(RepositoryRoot)
  let executable =
    when defined(macosx):
      "tmp/GotA Map Editor.app/Contents/MacOS/editor"
    elif defined(windows):
      "tmp/gota-editor.exe"
    else:
      "tmp/gota-editor"
  createDir(executable.parentDir)
  when defined(macosx):
    writeFile("tmp/GotA Map Editor.app/Contents/Info.plist", MacMetadata)
  let process = startProcess(
    CompilerPath,
    args = @[
      "c", "-d:release", "-o:" & executable, "examples/gods_of_the_arena/editor.nim"
    ],
    options = {poParentStreams}
  )
  defer:
    process.close()
  if process.waitForExit() != 0:
    raise newException(EditorBuildError, "The editor build failed.")
  echo "Editor built: ", absolutePath(executable)

buildEditor()
