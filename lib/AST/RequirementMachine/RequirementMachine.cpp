//===--- RequirementMachine.cpp - Generics with term rewriting ------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// A requirement machine is constructed from a collection of requirements over
// some set of generic parameters, and consists of a rewrite system together
// with a property map.
//
// The rewrite system and property map are used to answer questions about the
// type parameters expressed by this set of generic requirements. These are
// called "generic signature queries", and are defined as methods on the
// GenericSignature class; for example, two of the more common ones are
// getReducedType() and requiresProtocol().
//
// The terms of the rewrite system describe all possible type parameters that
// can be written -- the generic parameters themselves, together with all nested
// associated types generated by protocol conformances.
//
// The property map describes the requirements imposed on each type parameter,
// either directly by the user or implied by some protocol conformance.
//
// There are two "kinds" of requirement machines:
// - built from canonical, minimal generic signatures, used for queries,
// - built from user-written requirements, used to compute minimal generic
//   signatures.
//
// Ultimately, all minimal generic signatures are built by the second kind of
// requirement machine; the first kind consumes a minimal generic signature
// that was previously constructed, for example from a deserialized module.
//
// The second kind of requirement machine records additional information
// during completion.
//
// The second kind can become the first; after a minimal generic signature has
// been computed, the rewrite loops and other information only needed for
// minimization can be discarded.
//
// # Requirement machine initialization
//
// Requirement machines of the first kind are constructed by:
// - initWithProtocolSignatureRequirements()
// - initWithGenericSignature()
//
// The RewriteContext::getRequirementMachine() methods wrap the above with
// a lazy cache.
//
// Requirement machines of the second kind are constructed by:
// - initWithProtocolWrittenRequirements()
// - initWithWrittenRequirements()
//
// These are used from the implementations of RequirementSignatureRequest,
// AbstractGenericSignatureRequest and InferredGenericSignatureRequest
// in RequirementMachineRequests.cpp.
// 
// Both kinds of requirement machines undergo a multi-stage construction
// process which is best understood as a series of state transitions:
//
//  /--------------------------\
// |  Empty RequirementMachine |
//  \--------------------------/
//               |                      --------------
//               |                     / Requirement /
//               |                     --------------
//               |                           |
//               |                           v
//               |                    +-------------+
//               |                    | RuleBuilder |
//               |                    +-------------+
//               |                           |
//               |                           v
//               |                         -------
//               |                        / Rule /
//               |                        -------
//               |                           |
//               |   +-----------------------+
//               |   |
//               v   v
//      +----------------+
//      | Initialization |
//      +----------------+
//               |
//               v
//   /-----------------------------\
//  |  Initial RequirementMachine   |
//  |   /-----------------------\   |
//  |  |  Initial RewriteSystem  |  |
//  |   \-----------------------/   |
//   \------------------------------/
//               |
//               v
//        +------------+
//        | Completion |
//        +------------+
//               |
//               v
//   /------------------------------------------------------------------------\
//  |                      Complete RequirementMachine                         |
//  |                                                 +------ optional ----+   |
//  |  /-------------------------\   /-------------\  |  /--------------\  |   |
//  | |  Confluent RewriteSystem  | |  PropertyMap  | | |  RewriteLoops  | |   |
//  |  \-------------------------/   \-------------/  |  \--------------/  |   |
//  |                                                 +--------------------+   |
//   \------------------------------------------------------------------------/
//
//
// The RuleBuilder converts desugared requirements into rules. See
// RuleBuilder.cpp and RequirementLowering.cpp.
//
// Completion is an iterated process involving the Knuth-Bendix algorithm and
// property map construction, which are implemented in KnuthBendix.cpp and
// PropertyMap.cpp.
//
// # Requirement machine minimization
//
// A complete RequirementMachine of the second kind -- built from user-written
// requirements, with RewriteLoops recorded -- undergoes an additional state
// transition into a minimized state via a minimization process which identifies
// redundant rules. This is implemented in HomotopyReduction.cpp and
// MinimalConformances.cpp.
//
// After minimization, the remaining non-redundant rules are converted into
// the Requirements of a minimal generic signature by the RequirementBuilder.
// Then, the requirement machine undergoes a final state transition into the
// immutable "frozen" state:
//
//   /-----------------------------\
//  |  Complete RequirementMachine  |
//   \-----------------------------/
//                  |
//                  v
//           +--------------+            -------------------
//           | Minimization |  ------>  / RequirementError /
//           +--------------+           -------------------
//                  |
//                  v
//   /------------------------------\
//  |  Minimized RequirementMachine  |  ---------------+
//   \------------------------------/                  |
//                  |                                  v
//                  |                               -------
//                  |                              / Rule /
//                  v                              -------
//                  |                                  |
//                  |                                  v
//                  |                        +--------------------+
//                  |                        | RequirementBuilder |
//                  |                        +--------------------+
//                  |                                  |
//                  |                                  v
//                  |                            --------------
//                  |                           / Requirement /
//                  v                           --------------
//             +----------+
//             | Freezing |
//             +----------+
//                  |
//                  v
//    /---------------------------\
//   |  Frozen RequirementMachine  |
//    \---------------------------/
//
// # Generic signature queries
//
// Requirement machines of the first kind move into the "frozen" state
// immediately after completion.
//
//   /-----------------------------\
//  |  Complete RequirementMachine  |
//   \-----------------------------/
//                  |
//                  v
//             +----------+
//             | Freezing |
//             +----------+
//                  |
//                  v
//    /---------------------------\
//   |  Frozen RequirementMachine  |
//    \---------------------------/
//
// Once frozen, generic signature queries can be issued against the new
// requirement machine of either kind. These are implemented as methods on
// RequirementMachine in GenericSignatureQueries.cpp.
//
//===----------------------------------------------------------------------===//

#include "RequirementMachine.h"
#include "swift/AST/ASTContext.h"
#include "swift/AST/Decl.h"
#include "swift/AST/GenericSignature.h"
#include "swift/AST/PrettyStackTrace.h"
#include "swift/AST/Requirement.h"
#include "swift/Basic/Assertions.h"
#include "RequirementLowering.h"
#include "RuleBuilder.h"

using namespace swift;
using namespace rewriting;

RequirementMachine::RequirementMachine(RewriteContext &ctx)
    : Context(ctx), System(ctx), Map(System) {
  auto &langOpts = ctx.getASTContext().LangOpts;
  Dump = langOpts.DumpRequirementMachine;
  MaxRuleCount = langOpts.RequirementMachineMaxRuleCount;
  MaxRuleLength = langOpts.RequirementMachineMaxRuleLength;
  MaxConcreteNesting = langOpts.RequirementMachineMaxConcreteNesting;
  MaxConcreteSize = langOpts.RequirementMachineMaxConcreteSize;
  MaxTypeDifferences = langOpts.RequirementMachineMaxTypeDifferences;
  Stats = ctx.getASTContext().Stats;

  if (Stats)
    ++Stats->getFrontendCounters().NumRequirementMachines;
}

RequirementMachine::~RequirementMachine() {}

/// Checks the result of a completion in a context where we can't diagnose
/// failure, either when building a rewrite system from an existing
/// minimal signature (which should have been checked when it was
/// minimized) or from AbstractGenericSignatureRequest (where failure
/// is fatal).
void RequirementMachine::checkCompletionResult(CompletionResult result) const {
  switch (result) {
  case CompletionResult::Success:
    break;

  case CompletionResult::MaxRuleCount:
    ABORT([&](auto &out) {
      out << "Rewrite system exceeded maximum rule count\n";
      dump(out);
    });

  case CompletionResult::MaxRuleLength:
    ABORT([&](auto &out) {
      out << "Rewrite system exceeded rule length limit\n";
      dump(out);
    });

  case CompletionResult::MaxConcreteNesting:
    ABORT([&](auto &out) {
      out << "Rewrite system exceeded concrete type nesting depth limit\n";
      dump(out);
    });

  case CompletionResult::MaxConcreteSize:
    ABORT([&](auto &out) {
      out << "Rewrite system exceeded concrete type size limit\n";
      dump(out);
    });

  case CompletionResult::MaxTypeDifferences:
    ABORT([&](auto &out) {
      out << "Rewrite system exceeded concrete type difference limit\n";
      dump(out);
    });
  }
}

/// Build a requirement machine for the previously-computed requirement
/// signatures connected component of protocols.
///
/// This must only be called exactly once, before any other operations are
/// performed on this requirement machine.
///
/// Used by RewriteContext::getRequirementMachine(const ProtocolDecl *).
///
/// Returns failure if completion fails within the configured number of steps.
std::pair<CompletionResult, unsigned>
RequirementMachine::initWithProtocolSignatureRequirements(
    ArrayRef<const ProtocolDecl *> protos) {
  FrontendStatsTracer tracer(Stats, "build-rewrite-system");

  if (Dump) {
    llvm::dbgs() << "Adding protocols";
    for (auto *proto : protos) {
      llvm::dbgs() << " " << proto->getName();
    }
    llvm::dbgs() << " {\n";
  }

  RuleBuilder builder(Context, System.getReferencedProtocols());
  builder.initWithProtocolSignatureRequirements(protos);

  // Add the initial set of rewrite rules to the rewrite system.
  System.initialize(/*recordLoops=*/false, protos,
                    std::move(builder.ImportedRules),
                    std::move(builder.PermanentRules),
                    std::move(builder.RequirementRules));

  auto result = computeCompletion(RewriteSystem::DisallowInvalidRequirements);

  freeze();

  if (Dump) {
    llvm::dbgs() << "}\n";
  }

  return result;
}

/// Build a requirement machine for the requirements of a generic signature.
///
/// In this mode, minimization is not going to be performed, so rewrite loops
/// are not recorded.
///
/// This must only be called exactly once, before any other operations are
/// performed on this requirement machine.
///
/// Used by ASTContext::getOrCreateRequirementMachine().
///
/// Returns failure if completion fails within the configured number of steps.
std::pair<CompletionResult, unsigned>
RequirementMachine::initWithGenericSignature(GenericSignature sig) {
  Sig = sig;
  Params.append(sig.getGenericParams().begin(),
                sig.getGenericParams().end());

  PrettyStackTraceGenericSignature debugStack("building rewrite system for", sig);

  FrontendStatsTracer tracer(Stats, "build-rewrite-system");

  if (Dump) {
    llvm::dbgs() << "Adding generic signature " << sig << " {\n";
  }

  // Collect the top-level requirements, and all transitively-referenced
  // protocol requirement signatures.
  RuleBuilder builder(Context, System.getReferencedProtocols());
  builder.initWithGenericSignature(sig.getGenericParams(),
                                   sig.getRequirements());

  // Add the initial set of rewrite rules to the rewrite system.
  System.initialize(/*recordLoops=*/false,
                    /*protos=*/ArrayRef<const ProtocolDecl *>(),
                    std::move(builder.ImportedRules),
                    std::move(builder.PermanentRules),
                    std::move(builder.RequirementRules));

  auto result = computeCompletion(RewriteSystem::DisallowInvalidRequirements);

  freeze();

  if (Dump) {
    llvm::dbgs() << "}\n";
  }

  return result;
}

/// Build a requirement machine for the user-written requirements of connected
/// component of protocols.
///
/// This is used when actually building the requirement signatures of these
/// protocols. In this mode, minimization will be performed, so rewrite loops
/// are recorded during completion.
///
/// This must only be called exactly once, before any other operations are
/// performed on this requirement machine.
///
/// Used by RequirementSignatureRequest.
///
/// Returns failure if completion fails within the configured number of steps.
std::pair<CompletionResult, unsigned>
RequirementMachine::initWithProtocolWrittenRequirements(
    ArrayRef<const ProtocolDecl *> component,
    const llvm::DenseMap<const ProtocolDecl *,
                         SmallVector<StructuralRequirement, 4>> protos) {
  FrontendStatsTracer tracer(Stats, "build-rewrite-system");

  // For RequirementMachine::verify() when called by generic signature queries;
  // We have a single valid generic parameter at depth 0, index 0.
  Params.push_back(component[0]->getSelfInterfaceType()->castTo<GenericTypeParamType>());

  if (Dump) {
    llvm::dbgs() << "Adding protocols";
    for (auto *proto : component) {
      llvm::dbgs() << " " << proto->getName();
    }
    llvm::dbgs() << " {\n";
  }

  RuleBuilder builder(Context, System.getReferencedProtocols());
  builder.initWithProtocolWrittenRequirements(component, protos);

  // Add the initial set of rewrite rules to the rewrite system.
  System.initialize(/*recordLoops=*/true, component,
                    std::move(builder.ImportedRules),
                    std::move(builder.PermanentRules),
                    std::move(builder.RequirementRules));

  auto result = computeCompletion(RewriteSystem::AllowInvalidRequirements);

  if (Dump) {
    llvm::dbgs() << "}\n";
  }

  return result;
}

/// Build a requirement machine from a set of generic parameters and
/// structural requirements.
///
/// In this mode, minimization will be performed, so rewrite loops are recorded
/// during completion.
///
/// This must only be called exactly once, before any other operations are
/// performed on this requirement machine.
///
/// Used by AbstractGenericSignatureRequest and InferredGenericSignatureRequest.
///
/// Returns failure if completion fails within the configured number of steps.
std::pair<CompletionResult, unsigned>
RequirementMachine::initWithWrittenRequirements(
    ArrayRef<GenericTypeParamType *> genericParams,
    ArrayRef<StructuralRequirement> requirements) {
  Params.append(genericParams.begin(), genericParams.end());

  FrontendStatsTracer tracer(Stats, "build-rewrite-system");

  if (Dump) {
    llvm::dbgs() << "Adding generic parameters:";
    for (auto *paramTy : genericParams)
      llvm::dbgs() << " " << Type(paramTy);
    llvm::dbgs() << "\n";
  }

  // Collect the top-level requirements, and all transitively-referenced
  // protocol requirement signatures.
  RuleBuilder builder(Context, System.getReferencedProtocols());
  builder.initWithWrittenRequirements(genericParams, requirements);

  // Add the initial set of rewrite rules to the rewrite system.
  System.initialize(/*recordLoops=*/true,
                    /*protos=*/ArrayRef<const ProtocolDecl *>(),
                    std::move(builder.ImportedRules),
                    std::move(builder.PermanentRules),
                    std::move(builder.RequirementRules));

  auto result = computeCompletion(RewriteSystem::AllowInvalidRequirements);

  if (Dump) {
    llvm::dbgs() << "}\n";
  }

  return result;
}

/// Attempt to obtain a confluent rewrite system by iterating the Knuth-Bendix
/// completion procedure together with property map construction until fixed
/// point.
///
/// Returns a pair where the first element is the status. If the status is not
/// CompletionResult::Success, the second element of the pair is the rule ID
/// which triggered failure.
std::pair<CompletionResult, unsigned>
RequirementMachine::computeCompletion(RewriteSystem::ValidityPolicy policy) {
  while (true) {
    {
      unsigned ruleCount = System.getRules().size();

      // First, run the Knuth-Bendix algorithm to resolve overlapping rules.
      auto result = System.performKnuthBendix(MaxRuleCount, MaxRuleLength);

      unsigned rulesAdded = (System.getRules().size() - ruleCount);

      if (Stats) {
        Stats->getFrontendCounters()
            .NumRequirementMachineCompletionSteps += rulesAdded;
      }

      // Check for failure.
      if (result.first != CompletionResult::Success)
        return result;

      // Check invariants.
      System.verifyRewriteRules(policy);
    }

    {
      unsigned ruleCount = System.getRules().size();

      // Build the property map, which also performs concrete term
      // unification; if this added any new rules, run the completion
      // procedure again.
      Map.buildPropertyMap();

      unsigned rulesAdded = (System.getRules().size() - ruleCount);

      // If buildPropertyMap() didn't add any new rules, we are done.
      if (rulesAdded == 0)
        break;

      if (Stats) {
        Stats->getFrontendCounters()
          .NumRequirementMachineUnifiedConcreteTerms += rulesAdded;
      }

      // Check new rules added by the property map against configured limits.
      for (unsigned i = 0; i < rulesAdded; ++i) {
        const auto &newRule = System.getRule(ruleCount + i);
        if (newRule.getDepth() > MaxRuleLength + System.getLongestInitialRule()) {
          return std::make_pair(CompletionResult::MaxRuleLength,
                                ruleCount + i);
        }
        auto nestingAndSize = newRule.getNestingAndSize();
        if (nestingAndSize.first > MaxConcreteNesting + System.getMaxNestingOfInitialRule()) {
          return std::make_pair(CompletionResult::MaxConcreteNesting,
                                ruleCount + i);
        }
        if (nestingAndSize.second > MaxConcreteSize + System.getMaxSizeOfInitialRule()) {
          return std::make_pair(CompletionResult::MaxConcreteSize,
                                ruleCount + i);
        }
      }

      if (System.getLocalRules().size() > MaxRuleCount) {
        return std::make_pair(CompletionResult::MaxRuleCount,
                              System.getRules().size() - 1);
      }

      if (System.getTypeDifferenceCount() > MaxTypeDifferences) {
        return std::make_pair(CompletionResult::MaxTypeDifferences,
                              System.getRules().size() - 1);
      }
    }
  }

  if (Dump) {
    dump(llvm::dbgs());
  }

  ASSERT(!Complete);
  Complete = true;

  return std::make_pair(CompletionResult::Success, 0);
}

/// Transitions into a "frozen" state, where the requirement machine is now
/// immutable, and generic signature queries may be performed.
void RequirementMachine::freeze() {
  System.freeze();
}

ArrayRef<Rule> RequirementMachine::getLocalRules() const {
  return System.getLocalRules();
}

bool RequirementMachine::isComplete() const {
  return Complete;
}

GenericSignatureErrors RequirementMachine::getErrors() const {
  // FIXME: Assert if we had errors but we didn't emit any diagnostics?
  return System.getErrors();
}

void RequirementMachine::dump(llvm::raw_ostream &out) const {
  out << "Requirement machine for ";
  if (Sig)
    out << Sig;
  else if (!System.getProtocols().empty()) {
    auto protos = System.getProtocols();
    out << "protocols [";
    for (auto *proto : protos) {
      out << " " << proto->getName();
    }
    out << " ]";
  } else {
    out << "fresh signature <";
    for (auto paramTy : Params) {
      out << " " << Type(paramTy);
      if (paramTy->isParameterPack())
        out << " " << paramTy;
    }
    out << " >";
  }
  out << "\n";

  System.dump(out);
  Map.dump(out);

  out << "Conformance paths: {\n";
  for (auto pair : ConformancePaths) {
    out << "- " << pair.first.first << " : ";
    out << pair.first.second->getName() << " => ";
    pair.second.print(out);
    out << "\n";
  }
  out << "}\n";
}
