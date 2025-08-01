
file(TO_CMAKE_PATH "$ENV{WindowsSdkDir}" WindowsSdkDir)
file(TO_CMAKE_PATH "$ENV{WindowsSDKVersion}" WindowsSDKVersion)
file(TO_CMAKE_PATH "$ENV{UniversalCRTSdkDir}" UniversalCRTSdkDir)
file(TO_CMAKE_PATH "$ENV{UCRTVersion}" UCRTVersion)
file(TO_CMAKE_PATH "$ENV{VCToolsInstallDir}" VCToolsInstallDir)

file(CONFIGURE
  OUTPUT windows-sdk-overlay.yaml
  CONTENT [[
---
version: 0
case-sensitive: false
use-external-names: false
roots:
  - name: "@WindowsSdkDir@/Include/@WindowsSDKVersion@/um"
    type: directory
    contents:
      - name: module.modulemap
        type: file
        external-contents: "@CMAKE_CURRENT_SOURCE_DIR@/winsdk.modulemap"
  - name: "@UniversalCRTSdkDir@/Include/@UCRTVersion@/ucrt"
    type: directory
    contents:
      - name: module.modulemap
        type: file
        external-contents: "@CMAKE_CURRENT_SOURCE_DIR@/ucrt.modulemap"
  - name: "@VCToolsInstallDir@/include"
    type: directory
    contents:
      - name: module.modulemap
        type: file
        external-contents: "@CMAKE_CURRENT_SOURCE_DIR@/vcruntime.modulemap"
      - name: vcruntime.apinotes
        type: file
        external-contents: "@CMAKE_CURRENT_SOURCE_DIR@/vcruntime.apinotes"
]]
ESCAPE_QUOTES @ONLY NEWLINE_STYLE LF)

add_library(ClangModules INTERFACE)
target_compile_options(ClangModules INTERFACE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-vfsoverlay ${CMAKE_CURRENT_BINARY_DIR}/windows-sdk-overlay.yaml>")

install(TARGETS ClangModules
  EXPORT SwiftOverlayTargets)
install(FILES
  ucrt.modulemap
  vcruntime.apinotes
  vcruntime.modulemap
  winsdk.modulemap
  DESTINATION ${CMAKE_INSTALL_DATAROOTDIR})
