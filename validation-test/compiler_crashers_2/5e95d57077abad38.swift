// {"kind":"typecheck","signature":"swift::rewriting::RewriteContext::getRelativeTermForType(swift::CanType, llvm::ArrayRef<swift::rewriting::Term>)"}
// RUN: not --crash %target-swift-frontend -typecheck %s
extension Result {
  func a<each b>() where Success == (Result) -> (repeat each b)> {}
}
