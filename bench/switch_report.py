#!/usr/bin/env python3
"""Plot recorded switch ablations; does not execute database queries."""
import argparse
import json
from pathlib import Path

NAMES = {'batching':'Batching','deduplication':'Deduplication','result_cache':'Scan cache',
 'relational_prefilter':'Relational prefilter','kernel_plan_reuse':'SQL plan reuse',
 'selective_fallback':'Selective fallback','join_reduction':'Join reduction'}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('results',type=Path);args=p.parse_args()
 data=json.loads((args.results/'summary.json').read_text())
 import matplotlib
 matplotlib.use('Agg')
 import matplotlib.pyplot as plt
 from matplotlib.ticker import ScalarFormatter
 plt.rcParams.update({'font.size':11,'axes.spines.top':False,'axes.spines.right':False})
 fig,ax=plt.subplots(figsize=(11,6.4),layout='constrained')
 for y,r in enumerate(data):
  off,on=r['results'];ax.plot([on['median_ms'],off['median_ms']],[y,y],color='#b4bcc6',zorder=1)
  for v,color,offset,label in [(off,'#a05a16',-.09,'OFF'),(on,'#176fa6',.09,'ON')]:
   ax.errorbar(v['median_ms'],y+offset,xerr=[[v['median_ms']-v['min_ms']],[v['max_ms']-v['median_ms']]],fmt='o',color=color,capsize=3,markersize=6,label=label if y==0 else None)
  ax.text(1.02,y,f"{off['median_ms']:.2f} → {on['median_ms']:.2f} ms",transform=ax.get_yaxis_transform(),va='center')
 ax.set_yticks(range(len(data)),[NAMES[r['case']] for r in data]);ax.invert_yaxis()
 ax.set_xscale('log');ax.set_xlim(2,600);ax.set_xticks([2,5,10,20,50,100,200,500]);ax.xaxis.set_major_formatter(ScalarFormatter())
 ax.grid(axis='x',alpha=.2);ax.set_xlabel('Execution time, milliseconds (log scale; lower is better)')
 ax.set_title('Optimization switches: measured OFF vs ON',loc='left',pad=26)
 ax.text(0,1.035,'8,192 rows · 7 paired trials · points = medians · whiskers = min–max',transform=ax.transAxes)
 ax.legend(loc='lower right',frameon=False)
 fig.text(.01,-.085,'Deterministic providers, no network/LLM. Different workload per feature; effects are not additive.\nJoin reduction includes copies + reduction + inference + final join. Fallback confidence is synthetic.',fontsize=10)
 fig.savefig(args.results/'switches.png',dpi=180,bbox_inches='tight')
 fig.savefig(args.results/'switches.svg',bbox_inches='tight')
 plt.close(fig)

if __name__=='__main__':main()
