# DELSIM beam-spot override values derived from 94c data (2026-09-09)

Source: all 429 94c data files (edm4hep, same converter), 1,208,775 hadronic on-pole events with an AABTAG primary vertex
(>= 4 tracks), 1,823 runs. Script `beamspot_from_data.py`; per-run table `beamspot_94c_per_run.csv`
(columns: run, nev, AABTAG-PV mean/std x y z, PV fit sigma, DB beam spot x y z, DB widths, unfolded z width `ztrue`).

Event-weighted 1994 average (cm):   XYZP = -0.29977 0.14193 -0.60999     XYZW = 0.01153 0.00105 0.7035
  - centroid: AABTAG PV mean == DB beam spot mean to 2 um (x,y) / 16 um (z)
  - x width 0.1153 mm (DB median; unfolding the PV constraint gives 0.126 mm, consistent)
  - y width not measurable (within-run PV spread 0.008 mm = the 0.010 mm constraint); DB value 0.0105 mm kept
  - z width 7.03 mm = within-run PV spread with the fit resolution unfolded (DB median 6.92 mm)
Previous production (2026-09): XYZP -0.29911 0.14225 -0.6121 (fine), XYZW 0.01052 0.00512 0.1349 (y 5x too wide, z 5x too narrow).

Run-to-run drift of the centroid (event-weighted 5-95%): x -3.08..-2.92, y 1.31..1.51 (1.5 early -> 1.1 late 1994), z -8.0..-4.1 mm;
z width 5.8..8.6 mm.  `beamspot_for_seed.py <seed>` draws a run per job (probability ~ events) and prints XYZP/XYZW for it,
deterministically from the seed; `--global` prints the average.  b-tagging does not depend on either choice (AABTAG builds its
MC beam-spot constraint from the true vertex + the data-year widths); the choice matters for absolute vertex distributions.

## Use in a production job
`btag_condor/run_btag_job.sh` does this by default (`BEAMSPOT_MODE=per-job`):
```bash
eval "$(python3 "$REPO/beamspot/beamspot_for_seed.py" "$SEED" 2> beamspot.txt)"   # sets XYZP, XYZW (cm)
export XYZP XYZW                                                                  # picked up by run_delsim_only.sh
```
`BEAMSPOT_MODE=global` uses the 1994 average for every job; `BEAMSPOT_MODE=env` takes XYZP/XYZW as given.
The chosen run is written next to the GEN record as `<label>_<seed>.beamspot`.
`beamspot_from_data.py` (needs uproot/numpy) regenerates the table from converted data files; a 95d table can be made
the same way from the 95d data.
