#!/usr/bin/env python3
"""DELSIM beam-spot override for one production job, drawn from the 94c data run table.

Usage:  eval "$(python3 beamspot_for_seed.py <seed>)"          # per-job: XYZP/XYZW of a data run
        eval "$(python3 beamspot_for_seed.py <seed> --global)" # the event-weighted 1994 average
Prints  XYZP="x y z"  and  XYZW="wx wy wz"  (cm) on stdout; the chosen run on stderr.

Per job a data run is drawn with probability proportional to its number of selected hadronic events (its share of the
1994 luminosity), deterministically from the seed (random.Random(seed)).  XYZP = that run's primary-vertex centroid,
XYZW = (that run's beam-spot x width, 0.00105, that run's z width with the fit resolution unfolded).  Over a sample of
>= 20 jobs this reproduces the data's run-to-run centroid drift (x +-0.05, y +-0.07, z +-1.3 mm); with --global every
job gets the same centroid.  b-tagging does not depend on the choice (AABTAG builds its MC beam-spot constraint from the
true simulated vertex + the data-year widths); it matters for absolute vertex distributions only.
Table: beamspot_94c_per_run.csv (from beamspot_from_data.py on all 429 94c data files; runs with < 50 events dropped,
0.6% of the events).  Pure python, no numpy: runs on any worker node.
"""
import sys, os, csv, random
GLOBAL = ('-0.29977 0.14193 -0.60999', '0.01153 0.00105 0.7035')
def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]; opts = [a for a in sys.argv[1:] if a.startswith('--')]
    if not args: print(__doc__, file=sys.stderr); sys.exit(2)
    seed = int(args[0])
    table = next((o.split('=', 1)[1] for o in opts if o.startswith('--table=')), os.path.join(os.path.dirname(os.path.abspath(__file__)), 'beamspot_94c_per_run.csv'))
    if '--global' in opts:
        print(f'XYZP="{GLOBAL[0]}"'); print(f'XYZW="{GLOBAL[1]}"'); print('# global 1994 average', file=sys.stderr); return
    rows = [r for r in csv.DictReader(open(table)) if float(r['nev']) >= 50]
    weights = [float(r['nev']) for r in rows]
    r = random.Random(seed).choices(rows, weights=weights, k=1)[0]
    zt = float(r['ztrue']); zt = zt if zt > 3 else 7.035
    print(f'XYZP="{float(r["pv_x"])/10:.5f} {float(r["pv_y"])/10:.5f} {float(r["pv_z"])/10:.5f}"')
    print(f'XYZW="{float(r["bssig_x"])/10:.5f} 0.00105 {zt/10:.4f}"')
    print(f'# beam spot from data run {int(float(r["run"]))} ({int(float(r["nev"]))} hadronic events), seed {seed}', file=sys.stderr)
if __name__ == '__main__': main()
