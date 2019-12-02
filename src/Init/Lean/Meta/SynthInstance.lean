/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Daniel Selsam, Leonardo de Moura

Type class instance synthesizer using tabled resolution.
-/
import Init.Lean.Meta.Basic
import Init.Lean.Meta.Instances
import Init.Lean.Meta.LevelDefEq
import Init.Lean.Meta.AbstractMVars

namespace Lean
namespace Meta
namespace SynthInstance

structure Context :=
(config          : Config         := {})
(lctx            : LocalContext   := {})
(localInstances  : LocalInstances := #[])
(globalInstances : DiscrTree Expr := {})

structure GeneratorNode :=
(mctx            : MetavarContext)
(instances       : Array Expr)
(currInstanceIdx : Nat)

structure ConsumerNode :=
(mctx     : MetavarContext)
(subgoals : List Expr)
(answer   : MVarId)

inductive Waiter
| consumerNode : ConsumerNode → Waiter
| root         : Waiter

/-
We represent the tabled/cached entries using

1- An imperfect discrimination tree that stores the type class instances (i.e., types)
   an unique index.

2- A persistent array which represents a map from unique indices to `TableEntry`.
-/

structure Key :=
(key : AbstractMVarsResult)
(idx : Nat)

structure TableEntry :=
(waiters : Array Waiter)
(answers : Array AbstractMVarsResult)

structure State :=
(env            : Environment)
(cache          : Cache)
(ngen           : NameGenerator)
(traceState     : TraceState)
(mainMVarId     : MVarId)
(generatorStack : Array GeneratorNode         := #[])
(resumeStack    : Array (ConsumerNode × Expr) := #[])
(tableKeys      : DiscrTree Key               := {})
(tableEntries   : PersistentArray TableEntry  := {})

abbrev M := ReaderT Context (EStateM Exception State)

@[inline] private def getTraceState : M TraceState :=
do s ← get; pure s.traceState

@[inline] private def getOptions : M Options :=
do ctx ← read; pure ctx.config.opts

instance tracer : SimpleMonadTracerAdapter M :=
{ getOptions       := getOptions,
  getTraceState    := getTraceState,
  modifyTraceState := fun f => modify $ fun s => { traceState := f s.traceState, .. s } }

@[inline] def trace (cls : Name) (mctx : MetavarContext) (msg : Unit → MessageData) : M Unit :=
whenM (MonadTracerAdapter.isTracingEnabledFor cls) $ do
  ctx ← read;
  s   ← get;
  MonadTracerAdapter.addTrace cls (MessageData.context s.env mctx ctx.lctx (msg ()))

@[inline] def updateState (s : State) (newS : Meta.State) : State :=
{ env := newS.env, cache := newS.cache, ngen := newS.ngen, traceState := newS.traceState, .. s }

@[inline] def runMetaM {α} (x : MetaM α) (mctx : MetavarContext) : M (α × MetavarContext) :=
fun ctx s =>
  let r := (x { config := ctx.config, lctx := ctx.lctx, localInstances := ctx.localInstances }).run {
    env        := s.env,
    mctx       := mctx,
    cache      := s.cache,
    ngen       := s.ngen,
    traceState := s.traceState
  };
  match r with
  | EStateM.Result.error ex newS => EStateM.Result.error ex (updateState s newS)
  | EStateM.Result.ok a newS     => EStateM.Result.ok (a, newS.mctx) (updateState s newS)

def main (type : Expr) : MetaM (Option Expr) :=
pure none -- TODO

end SynthInstance

structure Replacements :=
(levelReplacements : Array (Level × Level) := #[])
(exprReplacements : Array (Expr × Expr)    := #[])

private def preprocess (type : Expr) : MetaM Expr :=
forallTelescopeReducing type $ fun xs type => do
  type ← whnf type;
  mkForall xs type

private def preprocessLevels (us : List Level) : MetaM (List Level × Array (Level × Level)) :=
do (us, r) ← us.foldlM
     (fun (r : List Level × Array (Level × Level)) (u : Level) => do
       u ← instantiateLevelMVars u;
       if u.hasMVar then do
         u' ← mkFreshLevelMVar;
         pure (u'::r.1, r.2.push (u, u'))
       else
         pure (u::r.1, r.2))
     ([], #[]);
    pure (us.reverse, r)

private partial def preprocessArgs (ys : Array Expr) : Nat → Array Expr → Array (Expr × Expr) → MetaM (Array Expr × Array (Expr × Expr))
| i, args, r => do
  if h : i < ys.size then do
    let y := ys.get ⟨i, h⟩;
    yType ← inferType y;
    if isOutParam yType then do
      if h : i < args.size then do
        let arg := args.get ⟨i, h⟩;
        arg' ← mkFreshExprMVar yType;
        preprocessArgs (i+1) (args.set ⟨i, h⟩ arg') (r.push (arg, arg'))
      else
        throw $ Exception.other "type class resolution failed, insufficient number of arguments" -- TODO improve error message
    else
      preprocessArgs (i+1) args r
  else
    pure (args, r)

private def preprocessOutParam (type : Expr) : MetaM (Expr × Replacements) :=
forallTelescope type $ fun xs typeBody =>
  match typeBody.getAppFn with
  | c@(Expr.const constName us _) => do
    env ← getEnv;
    if !hasOutParams env constName then pure (type, {})
    else do
      let args := typeBody.getAppArgs;
      cType ← inferType c;
      forallTelescopeReducing cType $ fun ys _ => do
        (us, levelReplacements)  ← preprocessLevels us;
        (args, exprReplacements) ← preprocessArgs ys 0 args #[];
        type ← mkForall xs (mkAppN (mkConst constName us) args);
        pure (type, { levelReplacements := levelReplacements, exprReplacements := exprReplacements })
  | _ => pure (type, {})

private def resolveReplacements (r : Replacements) : MetaM Bool :=
r.levelReplacements.allM (fun ⟨u, u'⟩ => isLevelDefEqAux u u')
<&&>
r.exprReplacements.allM (fun ⟨e, e'⟩ => isExprDefEqAux e e')

def synthInstance (type : Expr) : MetaM (Option Expr) :=
usingTransparency TransparencyMode.reducible $ do
  type ← preprocess type;
  s ← get;
  match s.cache.synthInstance.find type with
  | some result => pure result
  | none        => do
    result ← withNewMCtxDepth $ do {
      (normType, replacements) ← preprocessOutParam type;
      trace `Meta.synthInstance $ fun _ => normType;
      result? ← SynthInstance.main normType;
      match result? with
      | none        => pure none
      | some result => do
        condM (resolveReplacements replacements)
          (do result ← instantiateMVars result;
              condM (hasAssignableMVar result)
                (pure none)
                (pure (some result)))
          (pure none)
    };
    if type.hasMVar then do
      modify $ fun s => { cache := { synthInstance := s.cache.synthInstance.insert type result, .. s.cache }, .. s };
      pure result
    else
      pure result

end Meta
end Lean
