// RUN: %swift -target %host_triple -emit-ir -parse-as-library -disable-legacy-type-info -module-name dllexport %s -o - | %FileCheck %s -check-prefix CHECK -check-prefix CHECK-NO-OPT
// RUN: %swift -target %host_triple -O -emit-ir -parse-as-library -disable-legacy-type-info -module-name dllexport %s -o - | %FileCheck %s -check-prefix CHECK -check-prefix CHECK-OPT

// REQUIRES: OS=windows-msvc

import Swift

public protocol p {
  func f()
}

open class c {
  public init() { }
}

public var ci : c = c()

open class d {
  private func m() -> Never {
    fatalError()
  }
}

// CHECK-DAG: @"$s9dllexport2ciAA1cCvp" = dllexport global ptr null
// CHECK-DAG: @"$s9dllexport1pMp" = dllexport constant
// CHECK-DAG: @"$s9dllexport1cCMn" = dllexport constant
// CHECK-DAG: @"$s9dllexport1cCN" = dllexport alias %swift.type
// CHECK-DAG: @"$s9dllexport1dCN" = dllexport alias %swift.type
// CHECK-DAG-OPT: @"$s9dllexport1dC1m33_C57BA610BA35E21738CC992438E660E9LLs5NeverOyf" = dllexport alias void (), ptr @_swift_dead_method_stub
// CHECK-DAG-OPT: @"$s9dllexport1dCACycfc" = dllexport alias void (), ptr @_swift_dead_method_stub
// CHECK-DAG-OPT: @"$s9dllexport1cCACycfc" = dllexport alias void (), ptr @_swift_dead_method_stub
// CHECK-DAG-OPT: @"$s9dllexport1cCACycfC" = dllexport alias void (), ptr @_swift_dead_method_stub
// CHECK-DAG: define dllexport swiftcc ptr @"$s9dllexport1cCfd"(ptr{{.*}})
// CHECK-DAG-NO-OPT: define dllexport swiftcc ptr @"$s9dllexport1cCACycfc"(ptr %0)
// CHECK-DAG-NO-OPT: define dllexport swiftcc ptr @"$s9dllexport1cCACycfC"(ptr %0)
// CHECK-DAG: define dllexport swiftcc {{(noundef )?(nonnull )?}}ptr @"$s9dllexport2ciAA1cCvau"()
// CHECK-DAG-NO-OPT: define dllexport swiftcc void @"$s9dllexport1dC1m33_C57BA610BA35E21738CC992438E660E9LLs5NeverOyF"(ptr %0)
// CHECK-DAG-NO-OPT: define dllexport swiftcc void @"$s9dllexport1dCfD"(ptr %0)
// CHECK-DAG: define dllexport swiftcc ptr @"$s9dllexport1dCfd"(ptr{{.*}})
// CHECK-DAG: define dllexport swiftcc %swift.metadata_response @"$s9dllexport1cCMa"(i64 %0)
// CHECK-DAG: define dllexport swiftcc %swift.metadata_response @"$s9dllexport1dCMa"(i64 %0)
// CHECK-DAG-NO-OPT: define dllexport swiftcc ptr @"$s9dllexport1dCACycfc"(ptr %0)
// CHECK-DAG-OPT: define dllexport swiftcc void @"$s9dllexport1dCfD"(ptr %0)

