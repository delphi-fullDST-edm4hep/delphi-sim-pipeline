# delphi-sim — a generic generator front-end for the DELPHI legacy detector simulation

`delphi-sim` plugs **any** modern HEP event generator into the DELPHI (LEP, 1989–2000) detector
simulation + reconstruction chain. A generator produces a HepMC3 event record; a single,
generator-agnostic converter (`hepmc2fadgen`) turns it into the Fortran-unformatted **LUJETS
dump** (`fort.26`, a.k.a. a FADGEN file) that the legacy DELPHI simulation **DELSIM** reads; DELSIM
+ **DELANA** then produce DELPHI **shortDST** (`.sdst`) and **fullDST** (`.fadana`) files that feed
the standard DELPHI analysis tooling (e.g. [delphi-nanoaod](https://github.com/jingyucms/delphi-nanoaod)).

The single reusable core is the `fort.26` boundary. Everything upstream of it (the generator) is
swappable; everything downstream (DELSIM/DELANA/DST) is the frozen legacy chain. Generators wired in
today: native **Pythia8** (its own in-process `EventWriter`), and via **key4hep on CVMFS**:
**Pythia8** (Simple + Vincia showers), **Sherpa**, **Herwig7**, **Whizard**, **KKMCee** (parton-level,
parked); plus a legacy **KK2F** Fortran pipeline and a **bring-your-own external HepMC3** drop-in path.

Physics target throughout: e⁺e⁻ → γ\*/Z → hadrons **at the Z pole** (`eCM` 91.2 GeV; DELSIM default
`EBEAM 45.5935` = `eCM` 91.187; DELPHI processing `VERSION v94c`).

```
  generator (Pythia8 / Sherpa / Herwig / Whizard / KKMCee / external)
        │
        │  HepMC3 ASCII  (events.hepmc3)            ── native Pythia8 skips this:
        ▼                                              its EventWriter writes fort.26 directly
  ┌───────────────────┐
  │  hepmc2fadgen      │  generic HepMC3 → LUJETS converter (deduce_reader auto-format)
  └───────────────────┘
        │
        │  fort.26  (Fortran-unformatted LUJETS dump = "FADGEN" file)   ◄── THE BOUNDARY
        ▼                                                                    (the only artifact that
  ┌───────────────────┐                                                      crosses into the .sif)
  │  DELSIM (runsim)   │  detector simulation  ── runs INSIDE delphi-sim.sif (singularity/apptainer)
  │   + DELANA         │  reconstruction
  └───────────────────┘
        │
        ├──►  simana_<job>.sdst    shortDST  (MVDH VD-hit bank; for SKELANA / delphi-nanoaod)
        └──►  simana_<job>.fadana  fullDST   (per-track 3-D track elements PA.TETP/TEID/TEOD/TEFA/TEFB)
```

The pipeline runs as **two deliberately env-isolated subshells**, with `fort.26` as the only thing
that crosses between them:

- **Subshell A — generator + converter**, under **key4hep on CVMFS** (no container).
- **Subshell B — DELSIM/DELANA**, **inside `delphi-sim.sif`**, sourcing **NO key4hep**.

> **The single most important rule in this repo:** never `source` key4hep in the same shell you then
> run DELSIM (`delphi-sim.sif`) from. The generator stack must never leak into the container. See
> [Environment isolation](#environment-isolation-the-load-bearing-rule).

---

## Table of contents

1. [Repository layout](#1-repository-layout)
2. [Prerequisites & environment](#2-prerequisites--environment)
3. [Quick start](#3-quick-start-one-generator-end-to-end)
4. [The converter: hepmc2fadgen + audit tools](#4-the-converter-hepmc2fadgen--audit-tools)
5. [Generators (one subsection each)](#5-generators)
6. [The DELSIM step](#6-the-delsim-step)
7. [Building the binaries](#7-building-the-binaries)
8. [HTCondor production](#8-htcondor-production)
9. [Container image & CI](#9-container-image--ci)
10. [Output formats & converting to ROOT](#10-output-formats--converting-to-root)
11. [Troubleshooting & gotchas](#11-troubleshooting--gotchas)
12. [Status & provenance](#12-status--provenance)

---

## 1. Repository layout

Repo root (canonical AFS clone): `/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline`.
Docker Hub image `jingyucms/delphi-sim` — hence the name "delphi-sim".

```
delphi-pythia8-pipeline/
├── hepmc2fadgen.cpp / hepmc2fadgen   Shared, generator-AGNOSTIC HepMC3 → fort.26 converter (+ binary)
├── hepmc3_audit.py                   Pre-flight HepMC3 checker (beams/V0/b-hadron status histogram)
├── compare_fadgen.py                 Closure comparator for two fort.26 files (physics-equivalence)
├── build_key4hep.sh                  Builds the subshell-A C++ tools against key4hep (CVMFS)
├── run_generic.sh                    Shared driver: generate → hepmc2fadgen → DELSIM → DST
├── run_generic_condor.sh             Condor entry wrapper for the generic path (→ run_generic.sh)
├── run_delsim_only.sh               IN-CONTAINER DELSIM runner (calls `runsim`); baked into the .sif
├── m2_delsim_lxplus.sh               DELSIM step driver (subshell B): stages & runs the .sif on lxplus
├── condor_generic.sub                Generic key4hep vanilla-universe submit template (UNTESTED scaffold)
├── refresh_sif.sh                    Pull latest delphi-sim image from Docker Hub → swap AFS .sif (lxplus)
├── verify_sif.sh / refresh_sif.log   .sif sanity check (CHECK A converter byte-identity, CHECK B DELSIM)
├── delphi-sim.sif (~1.97 GB)         The DELSIM container image (untracked; pulled from Docker Hub/GHCR)
│
├── generators/
│   ├── pythia8/                      NATIVE Pythia8 (EventWriter → fort.26, no HepMC3); the .sif/production path
│   │   ├── pythia8_generate.cpp / Makefile     in-container C++11 build of the native generator
│   │   ├── run_pipeline.sh                       THE production driver (generate → DELSIM, runs inside .sif)
│   │   ├── run_in_singularity.sh                 Condor executable (vanilla universe; docker universe deprecated)
│   │   ├── condor_delphi.sub / submit_condor.sh  validated native-pythia8 submit file + batch submitter
│   │   ├── Dockerfile                            builds the delphi-sim image (context = repo ROOT)
│   │   ├── generate.sh                           bare smoke-test wrapper (fort.26 only, no DELSIM)
│   │   └── config_z_*.txt                        Pythia cards: qq / bb / cc / ss / light / ee / mm / tautau / ...
│   │
│   ├── pythia8_key4hep/              Pythia8 via key4hep (closure_gen) — Simple + Vincia showers
│   │   ├── closure_gen.cpp                        writes BOTH native fort.26 AND events.hepmc3
│   │   ├── generate.sh                            subshell A (key4hep child process)
│   │   ├── config_{default,vincia}_isr_{on,off}.txt   shower × ISR controlled-comparison configs
│   │   ├── run_{default,vincia}_prod.sh           VALIDATED production wrappers (SDST-only, per-job seeding)
│   │   ├── condor_{default,vincia}_prod.sub       validated submit files
│   │   └── submit_{default,vincia}_prod.sh        submit + scale wrappers (<variant> [total] [perjob])
│   │
│   ├── sherpa/                       Sherpa 3.x (MEPS/CKKW), ISR on/off
│   │   ├── generate.sh / Sherpa.yaml / Sherpa_isr_{on,off}.yaml
│   │   ├── integ_isr{in,off}/                     pre-computed integration grids (skip ~15-min integration)
│   │   ├── run_sherpa_prod.sh                     VALIDATED prod wrapper (saves HepMC3 + SDST)
│   │   ├── condor_sherpa_prod.sub / submit_sherpa_prod.sh
│   │   └── submit.sh                              generic-path submitter (UNTESTED scaffold)
│   │
│   ├── herwig/    generate.sh / LEP-DELPHI.in     Herwig 7.3 (HepMC2 IO_GenEvent output)
│   ├── whizard/   generate.sh / zhad.sin          Whizard 3.1.5 (PYTHIA6 hadronization; beams status 3)
│   ├── kkmc/      generate.sh                      KKMCee 5.01 (PARTON-LEVEL — BROKEN; no prod wrapper)
│   ├── kk2f/                          Legacy KK2F Fortran pipeline (DOCKER universe; deferred)
│   │   ├── run_kk2f_pipeline.sh / kk2f_fadgen_fixer.cpp / Dockerfile.kk2f
│   │   ├── kk2f_build/                            vendored KK2F sources + pretabulated tables (+ .inp/.tit)
│   │   └── condor_kk2f*.sub / submit_condor_kk2f.sh
│   └── hepmc3/    read_hepmc.sh / README.md       EXTERNAL HepMC3 drop-in path (audit → convert)
│
├── container/   run_singularity.sh / README.md    LOCAL run path: stock cmssw/el9 + CVMFS, no CERN net/Condor
└── .github/workflows/
    ├── docker.yml          builds & publishes the two images (delphi-sim + delphi-kk2f) to GHCR + Docker Hub
    └── smoke-test.yml      100-event end-to-end smoke test on every push to main / PR
```

The **shared root-level** tools (`hepmc2fadgen.cpp`, `run_delsim_only.sh`) are baked into the
`delphi-sim` image; the per-generator dirs hold each generator's own steering, `generate.sh`, and
(where they exist) production wrappers.

---

## 2. Prerequisites & environment

| Need | Where it lives | Used by |
|---|---|---|
| **CVMFS key4hep** | `/cvmfs/sw.hsf.org/key4hep/setup.sh` (override via `$KEY4HEP_SETUP`) | building the C++ tools; all key4hep generators (subshell A) |
| **CVMFS sft.cern.ch** | `/cvmfs/sft.cern.ch/...` | Herwig (CT14lo PDF, LHAPDF sets); the local `container/` path (LCG views) |
| **CVMFS delphi.cern.ch** | `/cvmfs/delphi.cern.ch/...` | the local `container/` path (DELPHI release + condition data) |
| **`delphi-sim.sif`** (~1.97 GB) | repo root (untracked; pulled from Docker Hub) | the DELSIM step (subshell B) |
| **singularity / apptainer** | lxplus or a condor worker | running the `.sif` |
| **AFS** | the repo + `.sif` live on AFS | jobs read these |
| **EOS** | production output destination | jobs write here |
| **Kerberos / AFS token** | `kinit` + `aklog` (the drivers run `aklog` for you) | AFS read + EOS write |

**Validated toolchain** (proven during M2 bring-up): key4hep **2026-04-08** = **Pythia8 8.315**,
**HepMC3 3.3.1** (soname `libHepMC3.so.4`), **gcc 14.2 / almalinux9**.

### What needs a container vs. not

- **Generation (key4hep)** needs **NO container** — key4hep is self-contained on CVMFS. It runs on a
  bare VM or on lxplus.
- **DELSIM** needs the **`.sif` + a singularity host** (lxplus or a condor worker). The bare VM has
  CVMFS/AFS/EOS/Kerberos but **no container runtime**, so it cannot run DELSIM. Drive DELSIM from the
  VM over Kerberos-delegated ssh:

  ```bash
  ssh -o PreferredAuthentications=gssapi-with-mic -o GSSAPIDelegateCredentials=yes \
      zhangj@lxplus.cern.ch 'bash /afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline/m2_delsim_lxplus.sh ...'
  ```

### Environment isolation (the load-bearing rule)

The converter binaries are **rpath-self-contained** (HepMC3 `lib64` is baked in with `-Wl,-rpath`),
so they run in a clean shell with **no key4hep on `LD_LIBRARY_PATH`**. Each generator's `generate.sh`
sources key4hep in its **own child process**; the converter and DELSIM run in the parent clean shell.
`m2_delsim_lxplus.sh` sources **no** key4hep and asserts a clean host `LD_LIBRARY_PATH`. This keeps
key4hep libraries out of the `.sif`. **Anti-pattern:** `source /cvmfs/sw.hsf.org/key4hep/setup.sh`
followed by `singularity exec delphi-sim.sif ...` in the same shell — do not do this.

---

## 3. Quick start: one generator end-to-end

> Run on **lxplus** (or a host with both CVMFS-key4hep and singularity). The bare VM can do the
> generation step but not DELSIM.

```bash
cd /afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline

# 1) Build the shared converter once (subshell A toolchain). Default = all four targets.
./build_key4hep.sh hepmc2fadgen          # or just: ./build_key4hep.sh

# 2) Run a generator end-to-end (generate → convert → DELSIM → DST).
#    run_generic.sh <generator> [nevents=20] [outdir=$PWD/<gen>_prod] [seed]
./run_generic.sh sherpa 20               # Sherpa; writes into ./sherpa_prod/
#   or:
./run_generic.sh pythia8_key4hep 20      # Pythia8 (key4hep)
```

What lands where (inside `<outdir>`, default `$PWD/<gen>_prod`):

```
sherpa_prod/events.hepmc3     generator output (HepMC3 ASCII)
sherpa_prod/fort.26           hepmc2fadgen output (the LUJETS dump)
sherpa_prod/fort.26.sdst      DELSIM shortDST  ◄── your result
```

`run_generic.sh` automatically over-generates ~10 % (see [the EOF-hang gotcha](#84-the-10--over-generation-buffer-the-delsim-eof-hang))
and runs DELSIM inside the `.sif` via `m2_delsim_lxplus.sh`. Valid `<generator>` values:
`pythia8_key4hep | sherpa | herwig | whizard | kkmc`.

> Native Pythia8 and KK2F have their **own** containerized drivers
> (`generators/pythia8/run_pipeline.sh`, `generators/kk2f/run_kk2f_pipeline.sh`) and do **not** use
> `run_generic.sh` — see [§5](#5-generators).

To run only the DELSIM step on a `fort.26` you already have:

```bash
./m2_delsim_lxplus.sh sherpa_prod/fort.26 20      # → sherpa_prod/fort.26.sdst
```

---

## 4. The converter: hepmc2fadgen + audit tools

These three files at the repo root are the **generator-agnostic boundary** of the whole pipeline.
Every key4hep generator and any external HepMC3 producer funnels through them.

### 4.1 `hepmc2fadgen` — the shared converter

```bash
hepmc2fadgen <input.hepmc> [output]      # output default: the literal "fort.26" (in CWD)
```

- **Auto-detects the HepMC3 ASCII variant** via HepMC3's `deduce_reader()` — handles both
  `HepMC3 Asciiv3` (Pythia8, Sherpa, Whizard, KKMC, closure_gen) and `IO_GenEvent`/HepMC2 (Herwig)
  transparently. The caller never specifies the format. **No env vars, no generator flag.**
- **HepMC3-only link** (no Pythia8) — that's what makes it generator-agnostic.

**Output record format** (Fortran-unformatted, little-endian), per event:
`int record_size`, `int N`, then per particle `K[5]` (int32), `P[5]` (float32), `V[5]` (float32),
then a trailing `int record_size`. `record_size = 4 + N*60`. The file ends with an end-marker triple
`(rec=4, n=0, rec=4)`.

**Encoding rules a manual must state:**

- **`V[5]` (vertex/lifetime) is written as all zeros on purpose.** DELSIM ignores the input
  production vertex (regenerates it from the beam spot via `SXBEAP`) and the input proper lifetime
  (uses its own `VTAU`/`UPTAU`). Filling real vertices would be silently discarded.
- **Status mapping** (HepMC3 status → LUJETS `K(,1)`):
  - HepMC3 **1** (final) → `K=1`, **except** V0 particles (see below) which final-state → **`K=4`**
    so DELSIM does the displaced decay.
  - **Everything else** (HepMC3 beam=4, decayed=2, documentation) → **`K=21`**.
  - **Critical caveat:** HepMC3 "decayed" (status 2) must **NOT** be mapped to LUJETS `K=2`. In
    JETSET `K(,1)=2` means "final, last of a colour singlet" (a *tracked* code); mislabeling a
    decayed Z/parton as 2 makes DELSIM reject the whole event (reads 0 input events). HepMC3 status
    and JETSET KS are different namespaces.
- **V0 set (`K=4`):** `{310 K0_S, 3122 Λ, 3112 Σ⁻, 3222 Σ⁺, 3312 Ξ⁻, 3322 Ξ⁰}` and antiparticles.
  **Ω 3334 is intentionally NOT included** (mirrors the native pipeline — do not "fix"). K0_L (130)
  is also not V0 (ctau ~15.3 m, detector-stable).
- **Beams first:** valid particles are `stable_partition`'d so HepMC3 status-4 beams (e⁺e⁻) lead the
  record — DELSIM/JETSET requires the two incoming beams at the front. *(Whizard marks beams status 3,
  not 4; they are still placed as `K=21` but are not hoisted by the status==4 partition — see
  [§5.5](#55-whizard).)*
- **Validity filter** drops `|pdg|==0`, JETSET special codes `81–99`, `|pdg|>=20000`, `|pdg|>100000`,
  and any particle with non-finite or `|p_i|,E > 1000` GeV.
- **Event rejection:** `N<2` valid particles; **`N>4000`** (DELSIM LUJETS arrays are dimensioned
  `(4000,5)`); fewer than 2 final-state (`K1∈{1,4}`) particles.
- Mother/daughter links (`K[2]`, `K[3]`, `K[4]`) are remapped to 1-based output indices, so the full
  gen tree (b-tagging truth) propagates to the DST SH-banks.

A copy of the converter is baked into the image at `/work/hepmc2fadgen` (used by `verify_sif.sh`).

### 4.2 `hepmc3_audit.py` — pre-flight checker

```bash
python3 hepmc3_audit.py file.hepmc3 [file2 ...]
```

Pure Python 3 stdlib (parses the ASCII directly; no HepMC3 libs) — runs anywhere with `python3`.
Prints, per file: format, event count, the full status histogram, **beam presence** (status 4),
final-state count/rate, the **V0 final-vs-decayed split per species**, and **b-hadron count by status**.

What the warnings mean:

- **`WARN: V0s DECAYED by generator → DELSIM loses displaced vertices`** — any V0
  (`{310,3122,3112,3222,3312,3322}`) arriving status 2. V0s must reach DELSIM **final-state
  (status 1)** so DELSIM regenerates the displaced decay.
- **`WARN: b-hadrons only final-state → DELSIM cannot decay them`** — any b-hadron
  (`500≤|pdg|<600` mesons, `5000≤|pdg|<6000` baryons) arriving status 1. b-hadrons should arrive
  **status 2 (decayed)** so the decay chain is in the record.
- **`beams (status 4): MISSING → converter must hoist beams`** — no status-4 beams (expected for
  Whizard, which uses status 3).

`hepmc3_audit.py` is run automatically by the external-HepMC3 path (`read_hepmc.sh`); skip with
`--no-audit`.

### 4.3 `compare_fadgen.py` — closure check

```bash
python3 compare_fadgen.py fort26_A fort26_B [--tol 1e-3]
```

Physics-equivalence (not byte-identity) comparator for two `fort.26` files (e.g. native EventWriter
output vs. `hepmc2fadgen` output). `--tol` (default `1e-3` GeV) is the momentum match tolerance —
particles are keyed by `(pdg, round(p/tol), round(E/tol))` since the two paths may order particles
differently. Reports final-state multiset match %, full-parentage-tree match %, b-tagging-truth match
%, and benign `2`↔`21` status-label disagreements. Prints `CLOSURE: PASS` only when event count,
every event's final-state set, and every event's parentage multiset all match exactly.

---

## 5. Generators

Common model: a per-generator `generate.sh` (subshell A) sources key4hep **in its own child
process**, produces `events.hepmc3`, then hands off to the shared tail `run_generic.sh` →
`hepmc2fadgen` → `m2_delsim_lxplus.sh`. **Native Pythia8 and KK2F are the two exceptions** — they
write `fort.26` directly and run in their own container images.

All generators must keep the **V0 set stable**: `{310, 3122, 3112, 3222, 3312, 3322}` + antiparticles
(K0_S, Λ, Σ⁻, Σ⁺, Ξ⁻, Ξ⁰). If a generator decays these itself, DELSIM silently loses every V0
displaced vertex. **K0_L (130) is deliberately NOT in the V0 set** (detector-stable). The V0
configuration differs per generator (table below).

Two **energy conventions** coexist (both Z-pole): **91.187 GeV** (closure_gen default, `Sherpa.yaml`,
Herwig, Whizard, KKMC default; beam half 45.5935) and **91.2 GeV** (the Pythia8 prod configs and both
Sherpa ISR variants; beam half 45.6). Pick deliberately.

| Generator | V0-stable mechanism | ISR on/off | Prod wrapper |
|---|---|---|---|
| native pythia8 | `mayDecay=false` + `K=4` in `.cpp` | per-card (`PDF:lepton`) | `run_pipeline.sh` (singularity) |
| pythia8_key4hep | `mayDecay=false` + `K=4` in `closure_gen.cpp` | `config_*_isr_{on,off}.txt` | `run_{default,vincia}_prod.sh` |
| sherpa | `Stable: 1` in YAML | `Sherpa_isr_{on,off}.yaml` | `run_sherpa_prod.sh` |
| herwig | `:Stable Stable` (Herwig decays by default!) | — | — |
| whizard | PYTHIA6 `MDCY(C<KF>,1)=0` | — | — |
| kkmc | n/a (broken/parton-level) | — | — (none) |
| kk2f | in `kk2f_fadgen_fixer` | `.KK2f_defaults` line 49 (`KeyISR`) | docker universe (deferred) |

### 5.1 Native Pythia8 (`generators/pythia8/`)

The ground-truth native DELPHI path. `pythia8_generate` writes `fort.26` directly via an in-process
`EventWriter` (no HepMC3, no `hepmc2fadgen`). This is the path the production `.sif` ships.

```bash
# Bare smoke test (fort.26 only, NO DELSIM):
generators/pythia8/generate.sh [nevents=20] [config=""] [outdir=$PWD/pythia8_run]

# Full production driver (runs INSIDE the .sif — see §6 / §8):
run_pipeline.sh [num_events=3000] [job_id=$(date)] [output_dir=/work/output] \
                [config_file=""] [delsim_version=v94c] [e_beam=45.625]
```

- `pythia8_generate [n=20] [config_file]` writes `fort.26` in CWD. **Seed is NOT user-settable** —
  it self-seeds from `(time+pid) % 9e8`. This is the reproducible-seeding gap.
- V0 particles are forced `mayDecay=false` and tagged JETSET status **4**. All final-state photons
  (any positive Pythia status, incl. status-63 beam-remnant) → status 1, so DELSIM/GEANT3 tracks them
  (fixes phantom missing energy; fixed 2026-06-06).
- **`config_z_*.txt` cards** (all `eCM=91.187`): `qq` (all 5 quarks), `bb`, `cc`, `ss` (the one wired
  into `condor_delphi.sub`), `light` (d,u), `ee`/`mm`/`tautau` (leptonic, FSR-populated), and
  `tautau_1prong` (forces `15:onMode=off; 15:onIfAny=211 -211`). Note `config_z_qq_dire.txt` uses
  `PartonShowers:model=3` and lacks `PDF:lepton=off` despite its "Dire" header.
- **`-STITL` 2-pass beam-spot gotcha** (in `run_pipeline.sh`): when `XYZP`/`XYZW` beam-spot overrides
  are set, it does a prerun **without** `-STITL` so `runsim`'s `MakeSimTitle()` fills the title
  placeholders, then `sed`-edits the beam spot and re-runs **with** `-STITL simlocal_edit.title`.
  **Passing `-STITL` with the raw template leaves placeholders unfilled, and DELSIM silently runs its
  internal qq generator (IGENER=15, NEVMAX=450) instead of your fadgen.** Per-period beam-spot
  defaults are baked in for `v94c` and `v95d`.

### 5.2 Pythia8 via key4hep (`generators/pythia8_key4hep/`) — default + Vincia

`closure_gen` is a Pythia8 generator (Z→hadrons) that writes **both** a native `fort.26` (EventWriter)
**and** `events.hepmc3` from the same accepted events — so it can both feed DELSIM directly and be
cross-checked with `compare_fadgen.py`.

```bash
generators/pythia8_key4hep/generate.sh [nevents=20] [config] [outdir=$PWD/pythia8_key4hep_run]
# or run end-to-end via the shared driver:
./run_generic.sh pythia8_key4hep 20
```

- **Four controlled-comparison configs**, identical except two knobs:
  - Shower: `PartonShowers:model = 1` (**Simple/default**) vs `= 2` (**Vincia**).
  - ISR: `PDF:lepton = on` (**physical** √s′ < 91.2) vs `off` (**monochromatic** 91.2 GeV reference).
  - All: `Beams:idA=11 idB=-11 eCM=91.2`, `WeakSingleBoson:ffbar2gmZ=on`, `23:onIfAny=1 2 3 4 5`.
- V0 stability is set in C++ (`mayDecay=false`, tagged `K=4`) **after** the config is read, so the
  configs intentionally omit it.
- **Vincia gotcha (load-bearing):** Vincia's HepMC3 is **not cleanly readable** by HepMC3
  `ReaderAscii` ("not enough implicit vertices" / empty incoming vertices). The Vincia path **must**
  use the native EventWriter `fort.26` and bypass `hepmc2fadgen` — which is exactly what the
  production wrappers (`run_{default,vincia}_prod.sh`, SDST-only) do.

### 5.3 Sherpa (`generators/sherpa/`)

Sherpa 3.x → `events.hepmc3` (Asciiv3).

```bash
generators/sherpa/generate.sh [nevents=20] [outdir=$PWD/sherpa_run]
# env: SHERPA_YAML (default Sherpa.yaml), SHERPA_SEED (→ Sherpa -R; REQUIRED in production)
```

- **`Sherpa.yaml`** is a minimal first-draft (LO q q̄, no merging, `BEAM_ENERGIES: 45.5935` →
  ECMS 91.187) — plumbing-proof only, **not** used by production.
- **`Sherpa_isr_{on,off}.yaml`** are the production MEPS configs (CKKW-merged 0..3 extra jets,
  `BEAM_ENERGIES: 45.6` → ECMS 91.2), verbatim from the Sherpa manual example
  *8.2.2.1 "MEPS setup for ee→jets"*. **ISR switch:** `_isr_on` enables ISR (electron structure
  function, the default); `_isr_off` adds `PDF_LIBRARY: None` to disable it (fixed 45.6 GeV/beam).
  V0 set via `Stable: 1` (covers particle + antiparticle).
- **`SHERPA_SEED` is mandatory in production** — without it, parallel jobs produce identical events.
- Pre-computed **integration grids** `integ_isrin/` and `integ_isroff/` are staged into scratch to
  skip the ~15-min CKKW integration (graceful fallback if absent).
- > Note the production **variant spelling is `isrin`** (not `isron`) for Sherpa — it also names the
  > `integ_isrin/` grid and the EOS subfolder.

### 5.4 Herwig (`generators/herwig/`)

Herwig 7.3 → `events.hepmc3` — but **Herwig emits HepMC2-style `IO_GenEvent` ASCII** (auto-handled by
`deduce_reader`).

```bash
generators/herwig/generate.sh [nevents=20] [outdir=$PWD/herwig_run]
```

- Steering `LEP-DELPHI.in`: e⁺e⁻ → γ/Z → hadrons at 91.187 GeV (`MEee2gZ2qq`).
- **Herwig decays the V0 set by default** — `LEP-DELPHI.in` sets `{K_S0,Lambda0,Sigma-,Sigma+,Xi-,Xi0}
  :Stable Stable` (`Synchronized` on, so antiparticles inherit). Without this DELSIM loses every V0
  vertex.
- **Two key4hep-specific gotchas** baked into `generate.sh`: (1) ThePEG/Herwig plugin libs in
  `lib/ThePEG` and `lib/Herwig` are not on `LD_LIBRARY_PATH` → the script prepends them (else
  `libThePEG.so.30: cannot open shared object file`); (2) Herwig wants CT14lo, which key4hep doesn't
  ship → sets `LHAPDF_DATA_PATH=/cvmfs/sft.cern.ch/lcg/external/lhapdfsets/current:...`. **Herwig
  therefore additionally requires the `sft.cern.ch` CVMFS repo.**

### 5.5 Whizard (`generators/whizard/`)

Whizard 3.1.5 → `events.hepmc3` (Asciiv3), with PYTHIA6 shower/hadronization.

```bash
# NOTE the argument order DIFFERS: outdir is $1, nevents is $2 (optional).
generators/whizard/generate.sh [outdir=$PWD/whizard_run] [nevents]
# run_generic.sh calls it specially as: generate.sh "$OUTDIR" "$NEV_GEN"
```

- Steering `zhad.sin`: SM, `sqrts = 91.187 GeV`. **Five separate processes** `ee_dd … ee_bb` (one per
  flavour, real masses kept) combined by cross-section — Whizard forbids a flavour-summed process with
  mixed masses. `?ps_fsr_active`, `?hadronization_active`, `$shower_method="PYTHIA6"`.
- V0 stability via PYTHIA6 `PYGIVE`: `MDCY(C310,1)=0; MDCY(C3122,1)=0; ...` (C<KF> = compressed code).
- **Whizard marks the e⁺e⁻ beams as status 3 (not 4).** `hepmc2fadgen` still places them first as
  `K=21`, but `hepmc3_audit.py` will report `beams (status 4): MISSING`. Verify beam placement before
  trusting Whizard input.

### 5.6 KKMCee (`generators/kkmc/`) — BROKEN / parked

```bash
generators/kkmc/generate.sh [nevents=20] [ecms=91.187] [outdir=$PWD/kkmc_run]
```

> **KNOWN LIMITATION (2026-06-06):** the key4hep KKMCee 5.01 build emits **PARTON-LEVEL** events
> (e⁺e⁻ → q q̄ + ISR; quarks status-1, **no hadrons**) despite `KeyHad=1`, with
> `cling::AutoLoadingVisitor` errors — the hadronization backend never engages. The output is **NOT
> hadron-level and NOT DELSIM-ready as-is**; the script even prints a `WARNING`. There is **no
> `run_kkmc_prod.sh`**. Resolution options: (a) fix the cling autoloading; (b) hadronize the parton
> HepMC3 downstream with Pythia8; (c) use the legacy KK2F Fortran path. Always run `hepmc3_audit.py`
> before trusting any KKMCee output.

### 5.7 Legacy KK2F (`generators/kk2f/`) — deferred, docker universe

Fortran pipeline: `kk2f_qq.exe` → `lund.output` → `kk2f_fadgen_fixer` → `my_events.fadgen` → DELSIM.
Runs in the **docker** image `jingyucms/delphi-kk2f-pipeline`.

```bash
run_kk2f_pipeline.sh [num_events=3000] [job_id=$(date)] [output_dir=/work/output] \
                     [isr_mode=on] [energy=91.187]
```

- **ISR toggle** edits **only line 49 (`KeyISR`) of `.KK2f_defaults`** (`on`→1 EEX, `off`→0). **You
  must delete the integration-grid cache `fort.51`/`fort.52` (also `fort.61/62`, `lund.output`,
  `kk2f.log`) before each run when switching ISR mode**, else the stale grid is reused.
- The `energy` arg drives **KK2F only** — DELSIM `EBEAM` is **hardcoded 45.625** and `VERSION` is
  hardcoded `v94c`. DELSIM runs on **90 %** of generated events (different buffer logic from pythia8).
- `kk2f_fadgen_fixer <in.fadgen> <out.fadgen>` re-applies the same V0 set + validity filter as the
  pythia8 path, operating directly on the Fortran-record binary.
- Validated σ (from comments): ISR ON ~30 nb / OFF ~12 nb at the Z-pole.
- All `condor_kk2f*.sub` use the **deprecated `universe=docker`** model and write to AFS
  (`/afs/.../output`), not EOS. `condor_kk2f_test.sub` passes a stale `.tit` as the ISR-mode arg
  (incompatible with the current "on"/"off" interface). KK2F large production is **deferred**.

### 5.8 External HepMC3 — bring your own (`generators/hepmc3/`)

Convert **any** external HepMC3 file (MadGraph, PanScales, or anything key4hep doesn't run
in-pipeline) to `fort.26` with no generator-specific code.

```bash
# Step 1 (once): build the converter
./build_key4hep.sh hepmc2fadgen

# Step 2: audit + convert
generators/hepmc3/read_hepmc.sh <input.hepmc> [out=fort.26] [--no-audit]

# Step 3 (lxplus): DELSIM
./m2_delsim_lxplus.sh <out> [nevmax] [ebeam]
```

`read_hepmc.sh` runs `hepmc3_audit.py` (unless `--no-audit`) then `hepmc2fadgen`. **Always audit
external HepMC3 first:** beams must be **status 4**; the V0 set must be **final-state (status 1)** or
DELSIM loses displaced vertices; b-hadrons should be **status 2 (decayed)**.

---

## 6. The DELSIM step

DELSIM runs **inside `delphi-sim.sif`** and sources **no key4hep** — the `fort.26` is the only
artifact that crosses into the container.

### 6.1 `m2_delsim_lxplus.sh` — the driver (subshell B)

```bash
m2_delsim_lxplus.sh <fadgen_file> [nevmax=20] [ebeam=45.5935] [version=v94c] [out_sdst]
# env: DELSIM_NRUN (default 100001) = DELSIM run number / RNG seed; vary per job in production
```

- `$3 EBEAM` default **45.5935** (= eCM 91.187 / 2). `$4 VERSION` default **v94c**.
- `$5 OUT_SDST` default `${FADGEN}.sdst` — **appends** `.sdst`, does not strip, because AFS paths
  contain dots (`cern.ch`).
- Requires `singularity`/`apptainer` on the host (**lxplus, NOT the bare VM** — it exits with
  "singularity not on this host"). Runs `aklog` for an AFS token. Asserts a **clean host
  `LD_LIBRARY_PATH`** (no key4hep).
- Mechanics: makes a `/tmp/m2_delsim.XXXXXX` scratch, stages the image's `/work` into it, copies the
  fadgen to `my_events.fadgen`, then:
  ```
  singularity exec --bind /afs:/afs --bind /eos:/eos --bind <scratch>:/work delphi-sim.sif \
      bash -lc "cd /work && ./run_delsim_only.sh <nevmax> <nrun> <ebeam> <version>"
  ```
- Outputs `simana.sdst` (copied to `$OUT_SDST`) and `simana.fadana` in scratch.

### 6.2 `run_delsim_only.sh` — the in-container runner

```bash
run_delsim_only.sh <nevmax> [nrun=100001] [ebeam=45.625] [version=v94c]
```

Must run **inside** the `.sif` with a writable `/work`; expects `my_events.fadgen` in CWD. It
hardcodes the entire DELPHI environment (release tag `dstana/161018` under
`/delphi/releases/almalinux-9-x86_64/latest/`, `DELPHI_DDB=/eos/opendata/delphi/condition-data` —
this is why `m2_delsim_lxplus.sh` bind-mounts `/eos`), prepends only `/usr/lib64:/lib64` to
`LD_LIBRARY_PATH`, then runs:

```
runsim -VERSION <version> -LABO CERN -NRUN <nrun> -EBEAM <ebeam> -NEVMAX <nevmax> -gext my_events.fadgen
```

Outputs `simana.sdst`, `simana.fadana` (and the large `simana.fadsim`, normally cleaned up).

> **EBEAM mismatch to note:** `run_delsim_only.sh`'s positional default is **45.625**, but
> `m2_delsim_lxplus.sh` always passes **45.5935** explicitly, so the in-container default is only seen
> if you call `run_delsim_only.sh` directly. Pick deliberately.

### 6.3 Benign noise

A `DCREPT: FATAL ERROR` line in the DELSIM log is **benign banner noise** — the pipeline completes
and the DST is produced anyway (confirmed in `verify_sif.log`: a 20-event Z→qq run produced a
552,960-byte `.sdst` despite that line). Don't chase it.

---

## 7. Building the binaries

```bash
./build_key4hep.sh [target ...]    # default (no args) = all four targets
#   targets: hepmc2fadgen  closure_gen  pythia8_generate  photon_diag
# env: KEY4HEP_SETUP (default /cvmfs/sw.hsf.org/key4hep/setup.sh)
```

Each binary is built **next to its source**: `hepmc2fadgen` at the repo root;
`generators/pythia8_key4hep/closure_gen`; `generators/pythia8/pythia8_generate`;
`generators/pythia8/photon_diag`. All are in `.gitignore`. Runs on the bare VM or lxplus (key4hep is
self-contained on CVMFS; no container needed). Validated against key4hep **2026-04-08** (Pythia8
8.315, HepMC3 3.3.1, gcc 14.2 / almalinux9).

**Gotchas baked into the script (all real M2 bring-up hits):**

- **Source key4hep directly** — never `source ... | tail`; a pipe runs `source` in a subshell and the
  env is lost.
- key4hep's `setup.sh` **expands unset vars**, so the script does **`set +u`** around the source (else
  `nounset` kills the shell).
- **HepMC3 headers are on `ROOT_INCLUDE_PATH`, NOT `CPLUS_INCLUDE_PATH`/`CPATH`** — g++ won't auto-find
  them, so the script locates `HepMC3/GenEvent.h` and passes `-I` explicitly.
- **HepMC3 3.3 bumped the soname to `libHepMC3.so.4`** (3.2.x was `.so.3`), and key4hep does **not**
  add the HepMC3 libdir to `LD_LIBRARY_PATH` → the build embeds **`-Wl,-rpath,<lib64>`** so the
  binaries are self-contained at runtime. (Confirmed via `readelf -d`: `NEEDED libHepMC3.so.4` +
  RPATH into the key4hep HepMC3 3.3.1 `lib64`.) **CVMFS must stay mounted at runtime**, but no
  `LD_LIBRARY_PATH` / key4hep-source is needed because rpath resolves it. If CVMFS rotates the
  2026-04-08 release away, rebuild with `build_key4hep.sh`.

The native-Pythia8 `Makefile` (`make pythia8_generate`, C++11, links `-lpythia8 -ldl`) is the
**in-container** build path; `build_key4hep.sh` is the **out-of-container** alternate (C++17, key4hep).

---

## 8. HTCondor production

**Submit from lxplus** (needs the condor client + a valid Kerberos ticket; the AFS token reaches the
worker via `MY.SendCredential=true`). The bare VM cannot submit (no condor client).

### 8.1 The validated model

Vanilla universe (**not** docker — key4hep comes from CVMFS, DELSIM from the AFS `.sif`) + transfer
only the small wrapper executable + `MY.SendCredential=true` (AFS `.sif` read + EOS write) +
worker-local scratch → copy the result to EOS. Common classads: `should_transfer_files=YES`,
`when_to_transfer_output=ON_EXIT`, **`transfer_output_files=""`** (the DST goes to EOS, not back via
condor), `getenv=False`, `requirements=(HasSingularity =?= true)`, `request_memory=4GB`,
`request_cpus=1`, `request_disk=10GB`.

Validated against a real condor run on **bigbird25, cluster 11053750, 2026-06-07**.

**Three submission tracks:**

| Track | Generators | `.sub` | Submit wrapper | Output | Status |
|---|---|---|---|---|---|
| **Pythia8 prod** | pythia8_key4hep (Simple/Vincia) | `condor_{default,vincia}_prod.sub` | `submit_{default,vincia}_prod.sh` | SDST | **validated** |
| **Sherpa prod** | sherpa | `condor_sherpa_prod.sub` | `submit_sherpa_prod.sh` | HepMC3 + SDST | **validated** |
| Generic (key4hep) | all five | `condor_generic.sub` | `generators/<gen>/submit.sh` | one `.sdst` | **UNTESTED scaffold** |

> The generic `generators/<gen>/submit.sh` scripts are **untested scaffolds** (their own headers say
> so) and pass **no per-job seed** — production-grade seeding exists only in the `*_prod` wrappers.

### 8.2 How to submit & scale

```bash
cd /afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline

# Pythia8 Simple shower, ISR on, 1.5M events @ 2500/job → 600 jobs:
generators/pythia8_key4hep/submit_default_prod.sh isron  [total=1500000] [perjob=2500]
# Pythia8 Vincia shower:
generators/pythia8_key4hep/submit_vincia_prod.sh  isroff [total=1500000] [perjob=2500]
# Sherpa (note variant spelling 'isrin'):
generators/sherpa/submit_sherpa_prod.sh           isrin  [total=1500000] [perjob=2500]
```

Scaling math: `NJOBS = ceil(total / perjob)` → defaults give **600 jobs × 2500 = 1.5 M events** per
variant. The submit wrappers create `condor_logs/` and then do, e.g.:

```bash
condor_submit generators/pythia8_key4hep/condor_default_prod.sub \
    -append "VARIANT = $VAR" -append "NEV = $PERJOB" -append "queue $NJOBS"
```

### 8.3 Per-job seeding

One per-job seed drives both the generator RNG and DELSIM's NRUN:

- **Pythia8 prod:** `SEED = (ClusterId % 80000) * 10000 + Process` (< 8e8; Pythia `Random:seed` max
  ~9e8). Injected by appending `Random:setSeed = on` / `Random:seed = <SEED>` to a per-job copy of the
  config (overrides closure_gen's internal seed → guaranteed-distinct events).
- **Sherpa prod:** `SEED = (ClusterId % 90000) * 10000 + Process` → Sherpa `-R` via `SHERPA_SEED`.
- **DELSIM everywhere:** `DELSIM_NRUN = 3000 + SEED % 88000` (RNG range proven by the native pipeline).

> **Seed-wiring caveat for the generic path:** `run_generic.sh` exports a *generator* seed only for
> Sherpa. Herwig/Whizard/KKMC/pythia8_key4hep get no generator-RNG seed (only DELSIM NRUN), and
> `condor_generic.sub` passes no seed at all — so parallel generic-path jobs of those generators would
> produce **correlated/duplicate physics**. The dedicated `*_prod` wrappers solve this; use them.

### 8.4 The 10 % over-generation buffer (the DELSIM EOF-hang)

`run_generic.sh` (and the `*_prod` wrappers, and the native `run_pipeline.sh` via `PYTHIA_BUFFER`)
**always over-generate ~10 %**: `NEV_GEN = NEV + ceil(NEV/10)`, with DELSIM `NEVMAX = NEV`. DELSIM
occasionally skips an event; reading past EOF triggers **`SXLUZE FATAL ERROR 106` ("NO PARTICLES
GENERATED BY LUND")** and DELSIM then **spins at ~100 % CPU forever**. This stalled **~12 % of the
first Sherpa run**. The `periodic_remove` watchdogs (3 h for `*_prod`, 12 h for generic) are only a
backstop — the over-generation is the real fix.

### 8.5 EOS output layout

```
Validated prod base: /eos/experiment/eealliance/Samples/DELPHI/1994/91.2/MC/94c/
   SDST/pythia8_default_isron/<DATE>/pythia8_default_isron_<CL>_<PR>.sdst
   SDST/pythia8_default_isroff/<DATE>/...
   SDST/pythia8_vincia_isron|isroff/<DATE>/...
   SDST/sherpa_isroff|isrin/<DATE>/sherpa_<variant>_<CL>_<PR>.sdst
   HEPMC3/sherpa_isroff|isrin/<DATE>/sherpa_<variant>_<CL>_<PR>.hepmc3   (Sherpa only)

Generic scaffold: /eos/user/z/zhangj/delphi_prod/<GEN>_<ClusterId>_<Process>/<gen>.sdst
```

`<DATE>` defaults to **`260607`**; override by exporting `DATE` (use a throwaway dir when validating).

### 8.6 Rules

- **Do NOT edit the `.sub` per-run.** They are templates; the `submit_*` scripts override
  `VARIANT`/`NEV`/`queue` via `condor_submit -append`. Edit a `.sub` only for a genuinely different
  pool (OUTBASE / requirements / JobFlavour).
- **Do NOT set the condor executable to `run_generic.sh` directly.** Use the wrapper
  (`run_generic_condor.sh` / `run_*_prod.sh`); it hardcodes the AFS `$REPO` so `generators/`,
  `hepmc2fadgen`, and the `.sif` resolve on the worker (condor ships only the executable to scratch).

### 8.7 Validate ONE job before scaling

```bash
# small NEV, single job, throwaway dated dir so nothing collides with real production:
DATE=val_$(date +%H%M%S) \
  condor_submit generators/pythia8_key4hep/condor_default_prod.sub \
    -append "VARIANT = isron" -append "NEV = 50" -append "queue 1"
# then: condor_q ; check the .sdst appears under SDST/pythia8_default_isron/<DATE>/
```

> Don't validate by `nohup`-ing a long DELSIM run on an lxplus login node — interactive jobs get
> reaped. Use `condor_submit ... queue 1` instead.

---

## 9. Container image & CI

Two images, both built with **build context = repo ROOT** so they bake the shared root-level
`hepmc2fadgen.cpp` + `run_delsim_only.sh`:

- **`delphi-sim`** (a.k.a. `delphi-sim-pipeline`) — the shared simulation container. GHCR
  `ghcr.io/jingyucms/delphi-sim-pipeline` (the GHCR namespace is `${{ github.repository_owner }}`) +
  Docker Hub `jingyucms/delphi-sim`. File
  `generators/pythia8/Dockerfile`. Builds **HepMC3 3.3.1 in-image** with the container's own
  AlmaLinux9 gcc (ABI-consistent with DELPHI — it does **not** drop the key4hep/gcc14 binaries in),
  bakes `/work/{Makefile,pythia8_generate.cpp,run_pipeline.sh,*.txt,hepmc2fadgen,run_delsim_only.sh}`,
  and pre-compiles `pythia8_generate`. `ENTRYPOINT ["/work/run_pipeline.sh"]`.
- **`delphi-kk2f`** (legacy) — GHCR `ghcr.io/jingyucms/delphi-kk2f-pipeline` + Docker Hub
  `jingyucms/delphi-kk2f-pipeline`. File `generators/kk2f/Dockerfile.kk2f`.

**CI** (`.github/workflows/docker.yml`): builds & publishes both images to GHCR + Docker Hub on push
to `main` and on image-affecting PRs (PRs **build but don't push**). `:latest` is tagged **only on
`main`**; every build also gets a commit-SHA tag. Docker Hub needs repo secrets `DOCKERHUB_USERNAME`
+ `DOCKERHUB_TOKEN`; GHCR uses the auto `GITHUB_TOKEN`.

**Smoke test** (`.github/workflows/smoke-test.yml`): on every push to `main` / PR, mounts CVMFS,
warms autofs, and runs a 100-event Pythia8 generation. **Mandatory** check: `./pythia8_generate 100`
produces a non-empty `fort.26`. DELSIM (full pipeline) and the delphi-nanoaod ROOT conversion
(ROOT 6.34.04; PHDST `T.FSEQ1` symlink workaround) are **continue-on-error**.

**Refreshing the AFS `.sif`** (run on **lxplus** — needs apptainer):

```bash
./refresh_sif.sh
```

It pulls `docker://jingyucms/delphi-sim:latest`, **verifies the baked artifacts**
(`/work/hepmc2fadgen`, `/work/run_delsim_only.sh`, `/work/pythia8_generate`, `libHepMC3.so*`), then
**atomically swaps** the AFS `delphi-sim.sif` (keeping the previous as `delphi-sim.sif.bak`).

> **`APPTAINER_CACHEDIR=/tmp` gotcha:** `refresh_sif.sh` sets `APPTAINER_CACHEDIR` and
> `APPTAINER_TMPDIR` to node-local `/tmp/...` (and pulls the new `.sif` to `/tmp` first) because the
> AFS HOME quota is far too small for the ~1.9 GB image + OCI→SIF conversion. Always pull to
> node-local scratch, never into AFS HOME.

---

## 10. Output formats & converting to ROOT

### EDM4hep conversion and FATMEN inputs

`convert_to_edm4hep.sh` is the pipeline entry point for the merged
[`delphi-edm4hep`](https://github.com/delphi-fullDST-edm4hep/delphi-edm4hep)
converter. It accepts exactly one of:

```bash
# A simulation shortDST produced by this repository
./convert_to_edm4hep.sh --input output/simana_42.sdst \
  --output output/simana_42.edm4hep.root --sample mc

# A DELPHI FATMEN nickname (resolved by PHDST/fatfind)
./convert_to_edm4hep.sh --nickname short94_c2/c1-10 \
  --output short94_c2_c1-10.edm4hep.root --sample data

# A PDLINPUT file prepared by fatfind
./convert_to_edm4hep.sh --pdl input.pdl \
  --output selected.edm4hep.root --sample data
```

Set `DELPHI_EDM4HEP_BIN` or pass `--edmbin` to select the directory containing
`delphi_sdst_pass` and `delphi_btag_check`. The checker runs on every output by
default. The merged converter always publishes both the stored BTG payload and
the recalculated AABTAG payload; the old pipeline-specific `--btag recalc`
steering is deliberately not exposed here.

DELSIM/DELANA produce two complementary files per job; **you want both for a complete refit.**

- **`simana_<job>.sdst` — DELPHI shortDST** (~150 kB / 30 events). Used by standard DELPHI analyses;
  the SKELANA-based [delphi-nanoaod](https://github.com/jingyucms/delphi-nanoaod) consumes this.
  Uniquely carries the **MVDH** VD-hit bank (event-level per-hit VD readout).
- **`simana_<job>.fadana` — DELPHI full-DST (DELANA output)** (~500 kB / 30 events). Carries the
  **per-track 3-D track elements** `PA.TETP` / `TEID` / `TEOD` / `TEFA` / `TEFB` that the shortDST
  strips. Needed for any hit-based refitting, particle-flow reconstruction, or alignment study.

> Some submission models intentionally drop the `.fadana` to save space (e.g.
> `generators/pythia8/run_in_singularity.sh` deletes it post-run, and KK2F never keeps it). The big
> intermediate `simana.fadsim` is always cleaned up.

### Convert to ROOT

Two options via [delphi-nanoaod](https://github.com/jingyucms/delphi-nanoaod):

- The **SKELANA-based RNTuple writer** — the standard path.
- On the `feature/phdst-raw-reader` branch, the new `delphi-raw-nanoaod` executable walks the ZEBRA
  banks directly via PHDST and emits calorimeter cells, VD hits, track-element 3-D points, raw
  lepton-ID, beamspot, vertices, and the B field. Same RNTuple schema for `.sdst` and `.fadana`
  inputs — which collections populate depends on the file format. See
  `feature/phdst-raw-reader/delphi-raw-nanoaod/README.md`. (CI demonstrates the conversion end-to-end:
  clone `delphi-nanoaod`, build in the image, ROOT 6.34.04, with the `T.FSEQ1` PHDST-input symlink
  workaround.)

### Local, no-CERN-network path

`container/run_singularity.sh` runs the full Pythia → DELSIM → DELANA → shortDST chain **locally** —
no lxplus, no Condor, no private image — using community `docker.io/cmssw/el9:x86_64` + CVMFS
(`sft.cern.ch`, `delphi.cern.ch`) mounted at runtime, with host `/lib64` bind-mounted at `/host_lib64`
for libgfortran / libXm / libXp / libquadmath (which `cmssw/el9` does not ship):

```bash
container/run_singularity.sh <n_events=200> <job_id=$(date)> <out_dir=$PWD/out> \
                             <config_file> [delsim_version=v94c] [e_beam=45.625]
# env: IMAGE_DIR (cache for the pulled .sif, default ~/.cache/singularity-delphi)
```

- **Config path is stale-default-prone:** the script's default `<config_file>` is
  `$PWD/../config_z_tautau.txt`, which no longer resolves after the per-generator reorg. **Pass an
  explicit path**, e.g. `generators/pythia8/config_z_tautau.txt`.
- Needs singularity ≥3.8 (or apptainer, rootless), CVMFS (`delphi.cern.ch` + `sft.cern.ch`), and an
  AlmaLinux 9 host with `motif` + `libgfortran` (+ `compat-libgfortran-48`). Uses LCG_109 (Pythia
  **8.317**), DELSIM `NRUN=3101` (hard-coded). Validated: **~660 kB `.sdst` for 100 Z→ττ events**.
- Note `e_beam` defaults to **45.625** here (vs. 45.5935 in `m2_delsim_lxplus.sh`).

---

## 11. Troubleshooting & gotchas

| Symptom | Cause | Fix |
|---|---|---|
| DELSIM **spins at ~100 % CPU forever**; log shows `SXLUZE FATAL ERROR 106` | DELSIM read past EOF of the LUJETS input | Over-generate ~10 % (`NEV_GEN = NEV + ceil(NEV/10)`) — already built into `run_generic.sh` / `*_prod` / `PYTHIA_BUFFER`. The `periodic_remove` watchdog is only a backstop. |
| Log shows `DCREPT: FATAL ERROR` but a DST is still produced | benign DELSIM banner noise | Ignore — the pipeline completed; check the `.sdst` size. |
| DELSIM "runs" but produces 450 internal-qq events, ignoring your fadgen | `-STITL` given a raw, unfilled title template (IGENER=15, NEVMAX=450) | Use the 2-pass flow in `run_pipeline.sh`: prerun WITHOUT `-STITL` to fill the title, then re-run WITH the `sed`-edited `simlocal_edit.title`. |
| `libHepMC3.so.4: cannot open shared object file` | HepMC3 3.3 soname is `.so.4` and key4hep doesn't add its libdir to `LD_LIBRARY_PATH` | Rebuild with `build_key4hep.sh` (embeds `-Wl,-rpath`); ensure CVMFS is mounted. |
| `libThePEG.so.30: cannot open shared object file` (Herwig) | ThePEG/Herwig plugin libs not on `LD_LIBRARY_PATH` | Use `generators/herwig/generate.sh` (it prepends `lib/ThePEG` + `lib/Herwig`). |
| `build_key4hep.sh` dies immediately / env not picked up | `nounset` vs key4hep's unset-var expansion, OR sourcing key4hep through a pipe | Source key4hep **directly** with `set +u` (the script does this — don't `source ... | tail`). |
| DELSIM rejects every event (reads 0 input) | HepMC3 status 2 mapped to LUJETS `K=2` (a tracked code) | Never map status 2 → `K=2`; the converter maps decayed → `K=21`. |
| V0 displaced vertices missing in the DST | generator decayed the V0 set itself | Make the V0 set `{310,3122,3112,3222,3312,3322}` final-state (status 1); audit with `hepmc3_audit.py`. |
| `compare_fadgen.py` shows only `2`↔`21` diffs | benign intermediate status labels | Not a failure — PASS requires identical final-state set + parentage, which these don't break. |
| Whizard input flagged `beams (status 4): MISSING` | Whizard marks beams status 3 | Expected; converter still places them as `K=21` — verify placement before trusting. |
| `.sdst` filename truncated at a dot (e.g. AFS path) | naive extension stripping | `m2_delsim_lxplus.sh` **appends** `.sdst` (never strips) because AFS paths contain dots. |
| key4hep libs leak into DELSIM / weird `.sif` crashes | key4hep sourced in the same shell as `singularity exec` | Keep the two subshells isolated; assert a clean host `LD_LIBRARY_PATH` before DELSIM. |
| `refresh_sif.sh` fails on AFS quota | pulling the ~1.9 GB image into AFS HOME | Pull to node-local `/tmp` with `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` (the script does this). |
| Long DELSIM run on an lxplus login node disappears | interactive/`nohup` jobs get reaped | Run via `condor_submit ... queue 1`, not `nohup`. |
| Parallel jobs produce identical events | Sherpa missing `SHERPA_SEED`, or a generic-path generator with no seed wiring | Use the `*_prod` wrappers (proper per-job seeding); Sherpa needs `SHERPA_SEED` (`-R`). |
| AFS reads fail mid-job ("no AFS token?") | token expired / not forwarded | `MY.SendCredential=true` in the `.sub`; drivers run `aklog`. Re-`kinit` on the submit host. |

---

## 12. Status & provenance

**Milestone arc.** M1 = native Pythia8 → DELSIM containerized & validated. M2 = generic
HepMC3 front-end + the `hepmc2fadgen` boundary + key4hep generators (subshell A/B isolation, the
rpath/soname fixes, the EOF-hang buffer) brought up against key4hep 2026-04-08. M3 = the validated
HTCondor production model (vanilla universe + `MY.SendCredential` + worker-local scratch → EOS),
validated on bigbird25 cluster 11053750 (2026-06-07), and the large ISR on/off productions below.

**Generator validation status:**

| Generator | Status |
|---|---|
| native Pythia8 | validated end-to-end (M1; the ground-truth path) |
| Pythia8 key4hep (Simple/Vincia) | validated end-to-end; in large production |
| Sherpa | validated end-to-end; large production complete |
| Herwig | validated end-to-end through DELSIM; no large ISR production yet |
| Whizard | validated end-to-end through DELSIM; no large ISR production yet |
| KKMCee | parton-level only (hadronization backend broken); parked |
| KK2F (legacy) | legacy Fortran path; large production deferred |

**Current productions** (e⁺e⁻ → Z → hadrons, Z pole, 94c):

- **Sherpa ISR on/off, 1.5 M × 2 — COMPLETE** (600/600 each).
- **Pythia8 + Vincia ISR on/off, 1.5 M × 2** — `isron` 600/600; `isroff` 599/600 (one process to
  backfill).
- **Pythia8 default (Simple shower) ISR on/off, 1.5 M × 2 — LAUNCHED, running** (clusters
  `11244137` isroff / `11244138` isron).
- **Herwig / Whizard** — validated through DELSIM, no large ISR production yet.
- **KKMCee** — parton-level, parked. **KK2F** — legacy, deferred.

---

### A note on the previous README

The prior root `README.md` is **stale and has been fully replaced** by this document. For the record,
the stale facts it contained (now corrected here): it referenced `condor_delphi.sub`,
`submit_condor.sh`, and `config_z_tautau.txt` at the **repo root** — after the per-generator reorg
they all live under **`generators/pythia8/`**; it claimed the local container path was on branch
`feature/cmssw-el9-base` (it is present in this checkout); and both quickstarts used
`../config_z_tautau.txt`, which no longer resolves (use `generators/pythia8/config_z_tautau.txt`).
