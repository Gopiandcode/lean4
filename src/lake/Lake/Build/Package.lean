/-
Copyright (c) 2022 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
import Lake.Util.Git
import Lake.Util.Sugar
import Lake.Build.Common
import Lake.Build.Targets

/-! # Package Facet Builds
Build function definitions for a package's builtin facets.
-/

open System
namespace Lake

/-- Compute a topological ordering of the package's transitive dependencies. -/
def Package.recComputeDeps (self : Package) : FetchM (Array Package) := do
  (·.toArray) <$> self.deps.foldlM (init := OrdPackageSet.empty) fun deps dep => do
    return (← fetch <| dep.facet `deps).foldl (·.insert ·) deps |>.insert dep

/-- The `PackageFacetConfig` for the builtin `depsFacet`. -/
def Package.depsFacetConfig : PackageFacetConfig depsFacet :=
  mkFacetConfig Package.recComputeDeps

/--
Build the `extraDepTargets` for the package and its transitive dependencies.
Also fetch pre-built releases for the package's' dependencies.
-/
def Package.recBuildExtraDepTargets (self : Package) : FetchM (BuildJob Unit) := do
  let mut job := BuildJob.nil
  -- Build dependencies' extra dep targets
  for dep in self.deps do
    job ← job.mix <| ← dep.extraDep.fetch
  -- Fetch pre-built release if desired and this package is a dependency
  if self.name ≠ (← getWorkspace).root.name ∧ self.preferReleaseBuild then
    job ← job.add <| ← (← self.release.fetch).attempt.bindSync fun success t => do
      unless success do
        logWarning "fetching cloud release failed; falling back to local build"
      return ((), t)
  -- Build this package's extra dep targets
  for target in self.extraDepTargets do
    job ← job.mix <| ← self.fetchTargetJob target
  return job

/-- The `PackageFacetConfig` for the builtin `dynlibFacet`. -/
def Package.extraDepFacetConfig : PackageFacetConfig extraDepFacet :=
  mkFacetJobConfig Package.recBuildExtraDepTargets

/-- Download and unpack the package's prebuilt release archive (from GitHub). -/
def Package.fetchRelease (self : Package) : SpawnM (BuildJob Unit) :=
  withRegisterJob "Fetching {self.name} cloud release" <| Job.async do
  let repo := GitRepo.mk self.dir
  let repoUrl? := self.releaseRepo? <|> self.remoteUrl?
  let some repoUrl := repoUrl? <|> (← repo.getFilteredRemoteUrl?)
    | error <| s!"{self.name}: wanted prebuilt release, " ++
      "but package's repository URL was not known; it may need to set `releaseRepo?`"
  let some tag ← repo.findTag?
    | error <| s!"{self.name}: wanted prebuilt release, " ++
      "but could not find an associated tag for the package's revision"
  let url := s!"{repoUrl}/releases/download/{tag}/{self.buildArchive}"
  let logName := s!"{self.name}/{tag}/{self.buildArchive}"
  let depTrace := Hash.ofString url
  let traceFile := FilePath.mk <| self.buildArchiveFile.toString ++ ".trace"
  let upToDate ← buildUnlessUpToDate? self.buildArchiveFile depTrace traceFile do
    logVerbose s!"downloading {logName}"
    download url self.buildArchiveFile
  unless upToDate && (← self.buildDir.pathExists) do
    logVerbose s!"unpacking {logName}"
    untar self.buildArchiveFile self.buildDir
  return ((), .nil)

/-- The `PackageFacetConfig` for the builtin `releaseFacet`. -/
def Package.releaseFacetConfig : PackageFacetConfig releaseFacet :=
  mkFacetJobConfig (·.fetchRelease)

/-- Perform a build job after first checking for a cloud release for the package. -/
def Package.afterReleaseAsync (self : Package) (build : SpawnM (Job α)) : FetchM (Job α) := do
  if self.preferReleaseBuild ∧ self.name ≠ (← getRootPackage).name then
    (← self.release.fetch).bindAsync fun _ _ => build
  else
    build

/-- Perform a build after first checking for a cloud release for the package. -/
def Package.afterReleaseSync (self : Package) (build : JobM α) : FetchM (Job α) := do
  if self.preferReleaseBuild ∧ self.name ≠ (← getRootPackage).name then
    (← self.release.fetch).bindSync fun _ _ => build
  else
    Job.async build

open Package in
/--
A package facet name to build function map that contains builders for
the initial set of Lake package facets (e.g., `extraDep`).
-/
def initPackageFacetConfigs : DNameMap PackageFacetConfig :=
  DNameMap.empty
  |>.insert depsFacet depsFacetConfig
  |>.insert extraDepFacet extraDepFacetConfig
  |>.insert releaseFacet releaseFacetConfig
