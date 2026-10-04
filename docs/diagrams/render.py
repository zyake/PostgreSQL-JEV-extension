#!/usr/bin/env python3
"""Render documentation diagrams without a browser or GitHub's Mermaid loader.

Run `python3 docs/diagrams/render.py` with matplotlib installed. Layouts below
produce the checked-in PNG/SVG assets; .mmd files preserve the original diagrams.
"""
from pathlib import Path

import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch


OUT = Path(__file__).resolve().parent
matplotlib.rcParams.update({'font.family': 'DejaVu Sans', 'svg.fonttype': 'none',
                            'svg.hashsalt': 'jev-doc-diagrams'})
PALETTE = {
    'sql': ('#edf3fc', '#3265a0'),
    'kernel': ('#e7f5f1', '#147768'),
    'provider': ('#fff3df', '#aa6b14'),
    'result': ('#e9f0f7', '#34516c'),
    'check': ('#f0ebfb', '#7151a3'),
}


class Diagram:
    def __init__(self, title, subtitle, width, height):
        self.width, self.height = width, height
        self.fig = plt.figure(figsize=(width / 100, height / 100), facecolor='white')
        self.ax = self.fig.add_axes((0, 0, 1, 1))
        self.ax.set(xlim=(0, width), ylim=(height, 0))
        self.ax.axis('off')
        self.ax.text(36, 25, title, va='top', fontsize=19, weight='bold', color='#183149')
        self.ax.text(36, 61, subtitle, va='top', fontsize=11, color='#506579')

    def node(self, x, y, w, h, label, kind='sql', size=12.5):
        fill, stroke = PALETTE[kind]
        self.ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0,rounding_size=12',
                                        linewidth=1.5, edgecolor=stroke, facecolor=fill, zorder=3))
        self.ax.text(x + w / 2, y + h / 2, label, ha='center', va='center',
                     fontsize=size, color='#183149', linespacing=1.55, zorder=4)

    def arrow(self, points, label=None, at=None):
        for start, end in zip(points[:-2], points[1:-1]):
            self.ax.plot([start[0], end[0]], [start[1], end[1]], color='#647b8e', lw=1.7, zorder=1)
        self.ax.add_patch(FancyArrowPatch(points[-2], points[-1], arrowstyle='-|>',
                                         mutation_scale=14, linewidth=1.7, color='#647b8e',
                                         shrinkA=0, shrinkB=1, zorder=2))
        if label:
            self.ax.text(*at, label, ha='center', va='center', fontsize=10.5, color='#42596c',
                         bbox={'facecolor': 'white', 'edgecolor': 'none', 'pad': 3}, zorder=5)

    def footer(self, text):
        self.ax.text(36, self.height - 24, text, va='center', fontsize=10, color='#506579')

    def save(self, name):
        self.fig.savefig(OUT / f'{name}.png', dpi=160, facecolor='white', metadata={'Software': 'Matplotlib'})
        self.fig.savefig(OUT / f'{name}.svg', facecolor='white', metadata={'Date': None})
        plt.close(self.fig)


def architecture():
    d = Diagram('Two SQL entry points, one evaluation kernel',
                'Explicit evaluation and opt-in planner integration', 1120, 1080)
    d.node(40, 105, 330, 76, 'SQL prepares candidate rows')
    d.node(40, 225, 330, 76, 'Explicit batch / relation API')
    d.node(560, 105, 430, 76, 'WHERE jev.semantic_match')
    d.node(560, 225, 430, 76, 'Planner hook offers CustomPath')
    d.node(560, 345, 430, 76, 'CustomScan\nOrdinary filters + bounded buffers')
    d.node(560, 465, 430, 76, 'Pair cached in this scan?', 'check')
    d.node(70, 600, 440, 82, 'Shared SQL batch kernel\nSkip NULLs + deduplicate exact pairs', 'kernel')
    d.node(70, 725, 440, 76, 'Replaceable primary provider', 'provider')
    d.node(700, 725, 340, 76, 'Fallback provider', 'provider')
    d.node(320, 865, 440, 76, 'Restore every input occurrence', 'result')
    d.node(320, 977, 440, 62, 'PostgreSQL joins, filters and aggregates', 'result', size=12)
    d.arrow([(205, 181), (205, 225)])
    d.arrow([(775, 181), (775, 225)])
    d.arrow([(775, 301), (775, 345)])
    d.arrow([(775, 421), (775, 465)])
    d.arrow([(205, 301), (205, 570), (220, 570), (220, 600)])
    d.arrow([(775, 541), (775, 570), (410, 570), (410, 600)], 'No', (800, 559))
    d.arrow([(990, 503), (1080, 503), (1080, 903), (760, 903)], 'Yes', (1045, 480))
    d.arrow([(290, 682), (290, 725)])
    d.arrow([(510, 763), (700, 763)], 'Uncertain', (605, 743))
    d.arrow([(290, 801), (290, 903), (320, 903)], 'Confident /\nno cascade', (195, 835))
    d.arrow([(870, 801), (870, 835), (630, 835), (630, 865)])
    d.arrow([(540, 941), (540, 977)])
    d.footer('NULL text skips provider calls. Duplicate input occurrences remain duplicate output rows.')
    d.save('architecture')


def api_paths():
    d = Diagram('Explicit API and planner integration',
                'Both execution paths use the same provider contract', 1120, 785)
    d.node(50, 110, 430, 76, 'SQL prepares candidate rows')
    d.node(50, 230, 430, 76, 'jev.evaluate_batch')
    d.node(640, 110, 430, 76, 'Simple SELECT with semantic_match')
    d.node(640, 230, 430, 76, 'Opt-in hook\nCustomPath → CustomScan')
    d.node(640, 350, 430, 76, 'Ordinary filters + bounded buffer')
    d.node(290, 485, 540, 76, 'Batch kernel\nDeduplicate non-NULL pairs + provider batches', 'kernel')
    d.node(290, 600, 540, 62, 'Restore each input occurrence', 'result')
    d.node(290, 700, 540, 52, 'SQL joins / filters / aggregates', 'result')
    d.arrow([(265, 186), (265, 230)])
    d.arrow([(855, 186), (855, 230)])
    d.arrow([(855, 306), (855, 350)])
    d.arrow([(265, 306), (265, 458), (420, 458), (420, 485)])
    d.arrow([(855, 426), (855, 458), (700, 458), (700, 485)])
    d.arrow([(560, 561), (560, 600)])
    d.arrow([(560, 662), (560, 700)])
    d.save('api-paths')


def optimizations():
    d = Diagram('Where the optimizations reduce work',
                'Combined conceptual flow; join-tree reduction remains an explicit API operation', 1100, 1165)
    rows = [
        (110, 'Relational inputs', 'sql'),
        (225, 'Ordinary filters / explicit join-tree reduction', 'sql'),
        (340, 'Deduplicate identical text pairs', 'kernel'),
        (455, 'Result already cached in this scan?', 'check'),
        (570, 'Collect a provider batch', 'kernel'),
        (685, 'Primary provider: decision + confidence', 'provider'),
        (815, 'Configured fallback provider', 'provider'),
        (945, 'Restore every input occurrence', 'result'),
        (1060, 'Remaining SQL filters / final exact joins', 'result'),
    ]
    for y, label, kind in rows:
        d.node(50, y, 650, 72, label, kind)
    for first, second in [(0, 1), (1, 2), (2, 3), (4, 5), (6, 7), (7, 8)]:
        d.arrow([(375, rows[first][0] + 72), (375, rows[second][0])])
    d.arrow([(375, 527), (375, 570)], 'No', (415, 549))
    d.arrow([(375, 757), (375, 815)], 'Uncertain', (440, 787))
    d.arrow([(700, 491), (1020, 491), (1020, 965), (700, 965)], 'Yes: reuse result', (866, 469))
    d.arrow([(700, 721), (850, 721), (850, 997), (700, 997)], 'Confident', (793, 699))
    d.save('optimizations')


def sequence(name, title, subtitle, steps, footer, kinds):
    h = 140 + 110 * len(steps)
    d = Diagram(title, subtitle, 1000, h)
    for i, (label, kind) in enumerate(zip(steps, kinds)):
        y = 110 + i * 110
        d.node(115, y, 770, 70, f'{i + 1}.  {label}', kind)
        if i:
            d.arrow([(500, y - 40), (500, y)])
    d.footer(footer)
    d.save(name)


if __name__ == '__main__':
    architecture()
    api_paths()
    optimizations()
    sequence('join-reduction', 'Explicit join-tree reduction',
             'Exact semijoins remove rows with no relational join support',
             ['Caller prepares relational inputs', 'Copy visible rows once',
              'Bottom-up exact semijoins', 'Top-down exact semijoins',
              'Evaluate surviving semantic inputs', 'Final exact joins preserve multiplicities'],
             'Source tables remain unchanged. The caller connects reduction, evaluation and the final joins.',
             ['sql', 'sql', 'kernel', 'kernel', 'provider', 'result'])
    sequence('benchmark-workflow', 'One workload for all 128 switch combinations',
             'The same A, B and C source tables are used for every configuration',
             ['Same A, B, C source tables', 'Explicit join-tree reducer',
              'CustomScan on copied B: active AND semantic predicate',
              'Final exact joins to copied A and C', 'Stop server timer',
              'Compare full result bags with EXCEPT ALL in both directions'],
             'Correctness validation runs after timing. Duplicate multiplicities and NULL values are checked.',
             ['sql', 'kernel', 'provider', 'sql', 'result', 'check'])
    print('Rendered five documentation diagrams as PNG and SVG.')
