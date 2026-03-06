#!/usr/bin/env python3
"""Speak11 text normalizer — reads stdin, writes TTS-ready text to stdout.

Architecture: source detection -> front-end -> shared back-end.
Each front-end converts its source format into clean prose.
The back-end never knows the source.
"""
import re, sys, unicodedata as _ud, ftfy

# ── Shared data (used by front-ends and back-end) ────────────────

_SD = str.maketrans(
    '\u00b9\u00b2\u00b3\u2074\u2075\u2076\u2077\u2078\u2079\u2070',
    '1234567890')
_SUP_RE = r'[\u00b9\u00b2\u00b3\u2074-\u2079\u2070]+'

_COMPOUND_PREFIXES = frozenset({
    'self','non','quasi','semi','well','ill','all','half','cross','ex',
})

# Function-word gate for stripping PDF superscript citations mid-sentence.
_CITATION_FOLLOWERS = frozenset({
    'that','which','and','or','but','if','as','so','yet',
    'the','this','these','those','it','they','we','he','she','its',
    'has','have','had','was','were','is','are','been','can','could',
    'would','should','may','might','shall','will','did','does','do',
    'also','not','often','still','even','only','just',
    'in','on','to','for','at','by','with','from','of',
    'showed','found','reported','observed','noted','demonstrated',
    'suggested','indicated','revealed','confirmed','concluded',
})
_NUM_CONTEXT_WORDS = frozenset({
    'chapter','section','step','phase','stage','type','table','figure',
    'page','group','item','class','level','grade','round','trial',
    'volume','number','part','act','year','day','week','month',
    'case','rule','task','test','dose','factor','version','model',
    'least','most','only','approximately','about','nearly','almost',
    'over','under','around','exactly','roughly','fewer','more',
    'and','or','to','from','through','between','versus','times','equals',
    'another','other','further','additional','remaining',
    'next','last','first','every','each',
})
_CF_ALT = '|'.join(sorted(_CITATION_FOLLOWERS, key=len, reverse=True))
_CITE_PAT = re.compile(r'(\w+) (\d{1,2}) (?=(' + _CF_ALT + r')\b)')

_FRAC = {'\u00bd':'one half','\u2153':'one third','\u00bc':'one quarter',
  '\u00be':'three quarters','\u2154':'two thirds','\u2155':'one fifth',
  '\u2156':'two fifths','\u2157':'three fifths','\u2158':'four fifths',
  '\u2159':'one sixth','\u215a':'five sixths','\u215b':'one eighth',
  '\u215c':'three eighths','\u215d':'five eighths','\u215e':'seven eighths'}

_ELEM = {
  'H':'hydrogen','He':'helium','Li':'lithium','Be':'beryllium','B':'boron',
  'C':'carbon','N':'nitrogen','O':'oxygen','F':'fluorine','Ne':'neon',
  'Na':'sodium','Mg':'magnesium','Al':'aluminum','Si':'silicon',
  'P':'phosphorus','S':'sulfur','Cl':'chlorine','Ar':'argon',
  'K':'potassium','Ca':'calcium','Fe':'iron','Co':'cobalt','Ni':'nickel',
  'Cu':'copper','Zn':'zinc','Se':'selenium','Br':'bromine','Kr':'krypton',
  'Sr':'strontium','Mo':'molybdenum','Tc':'technetium','Ag':'silver',
  'Cd':'cadmium','I':'iodine','Xe':'xenon','Cs':'cesium','Ba':'barium',
  'La':'lanthanum','Ce':'cerium','Nd':'neodymium','Sm':'samarium',
  'Eu':'europium','Gd':'gadolinium','Tb':'terbium','Dy':'dysprosium',
  'Er':'erbium','Yb':'ytterbium','Lu':'lutetium','Hf':'hafnium',
  'Ta':'tantalum','W':'tungsten','Re':'rhenium','Os':'osmium',
  'Ir':'iridium','Pt':'platinum','Au':'gold','Hg':'mercury',
  'Pb':'lead','Bi':'bismuth','Po':'polonium','Rn':'radon',
  'Ra':'radium','Th':'thorium','U':'uranium','Np':'neptunium',
  'Pu':'plutonium','Am':'americium'}

_CHEM = {
  'H2O':'water','CO2':'carbon dioxide','NaCl':'sodium chloride',
  'CH4':'methane','NH3':'ammonia','H2SO4':'sulfuric acid',
  'HCl':'hydrochloric acid','NaOH':'sodium hydroxide',
  'CaCO3':'calcium carbonate','Fe2O3':'iron oxide',
  'C2H5OH':'ethanol','C6H12O6':'glucose','CH3OH':'methanol',
  'KOH':'potassium hydroxide','HNO3':'nitric acid',
  'Na2CO3':'sodium carbonate','MgO':'magnesium oxide',
  'SiO2':'silicon dioxide','SO2':'sulfur dioxide',
  'NO2':'nitrogen dioxide','O3':'ozone','N2O':'nitrous oxide',
  'C2H2':'acetylene','C2H4':'ethylene','C3H8':'propane',
  'ATP':'ATP','DNA':'DNA','RNA':'RNA'}
_CHEM_RE = re.compile(r'\b(' + '|'.join(sorted(_CHEM, key=len, reverse=True)) + r')\b')

# ── Source detection ──────────────────────────────────────────────

def _is_latex(t):
    """Score-based LaTeX detection with high-confidence guard + negative signals."""
    score = 0
    has_high = False
    # Negative signals: PDF artifacts mean this is almost certainly NOT LaTeX source.
    if any(c in t for c in '\ufb00\ufb01\ufb02\ufb03\ufb04'):
        score -= 5
    # Negative signal: ATX headings are Markdown, not LaTeX.
    if re.search(r'^#{1,6}\s', t, re.MULTILINE):
        score -= 3
    # High-confidence signals (score >= 2).
    if re.search(r'\\(?:begin|end)\{', t):        score += 3; has_high = True
    if re.search(r'\\\w+\{', t):                   score += 2; has_high = True
    if re.search(r'\$\$|\\\[|\\\(', t):            score += 2; has_high = True
    if re.search(r'(?<!\$)\$[^\$\n]+\$(?!\$)', t): score += 2; has_high = True
    if re.search(r'\\(?:frac|sum|int|prod|lim|sqrt|alpha|beta|gamma|delta|theta|lambda|mu|sigma|omega)\b', t):
        score += 2; has_high = True
    if re.search(r'\\(?:cite|ref|section)\{', t):  score += 2; has_high = True
    if re.search(r'\\(?:item|itemize|enumerate)\b', t): score += 2; has_high = True
    # Low-confidence signals (only count if we have at least one high-confidence).
    if has_high:
        if re.search(r'\\[a-zA-Z]+', t):            score += 1
        if re.search(r'^\s*%', t, re.MULTILINE):     score += 1
    return score >= 3

def _is_markdown(t):
    """Score-based Markdown detection with high-confidence guard."""
    score = 0
    has_high = False
    # High-confidence signals.
    if re.search(r'^```', t, re.MULTILINE):              score += 3; has_high = True
    if re.search(r'^#{1,6}\s', t, re.MULTILINE):          score += 2; has_high = True
    if re.search(r'\*\*[^*]+\*\*', t):                    score += 2; has_high = True
    if re.search(r'\[[^\]]+\]\([^)]+\)', t):               score += 2; has_high = True
    if re.search(r'!\[[^\]]*\]\([^)]+\)', t):              score += 2; has_high = True
    if re.search(r'\[\[[^\]]+\]\]', t):                    score += 2; has_high = True
    if re.search(r'\A---\s*\n', t):                        score += 2; has_high = True
    # Low-confidence signals (only if at least one high-confidence).
    if has_high:
        if re.search(r'^[-*+]\s', t, re.MULTILINE):        score += 1
        if re.search(r'^\d+\.\s', t, re.MULTILINE):        score += 1
        if re.search(r'^>\s', t, re.MULTILINE):             score += 1
        if re.search(r'^---\s*$', t, re.MULTILINE):         score += 1
        if re.search(r'`[^`]+`', t):                        score += 1
    return score >= 3

# ── Markdown front-end ────────────────────────────────────────────

def _frontend_markdown(t):
    """Convert Markdown source into clean prose (M1-M10)."""

    # ── M1: YAML frontmatter + Obsidian comments ──
    t = re.sub(r'\A---\s*\n.*?\n---\s*\n', '', t, flags=re.DOTALL)
    t = re.sub(r'%%.*?%%', '', t, flags=re.DOTALL)

    # ── M2: Code blocks (fenced only; indented code omitted to avoid false positives) ──
    t = re.sub(r'^```[^\n]*\n.*?\n```', 'Code block omitted.', t, flags=re.MULTILINE | re.DOTALL)

    # ── M3: Headings ──
    t = re.sub(r'^#\s+(.*?)$', r'Title: \1.', t, flags=re.MULTILINE)
    t = re.sub(r'^##\s+(.*?)$', r'Section: \1.', t, flags=re.MULTILINE)
    t = re.sub(r'^###\s+(.*?)$', r'Subsection: \1.', t, flags=re.MULTILINE)
    t = re.sub(r'^#{4,6}\s+(.*?)$', r'\1.', t, flags=re.MULTILINE)

    # ── M4: Images (standard + Obsidian wikilink) ──
    t = re.sub(r'!\[([^\]]+)\]\([^)]+\)', r'Image: \1.', t)
    t = re.sub(r'!\[\]\([^)]+\)', 'Image.', t)
    t = re.sub(r'!\[\[([^\]]+)\]\]', 'Image.', t)

    # ── M5: Links + wikilinks ──
    t = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', t)
    t = re.sub(r'\[\[([^|\]]+)\|([^\]]+)\]\]', r'\2', t)  # [[target|alias]]
    t = re.sub(r'\[\[([^\]]+)\]\]', r'\1', t)               # [[target]]

    # ── M6: Text formatting ──
    t = re.sub(r'\*\*([^\n]+?)\*\*', r'\1', t)      # bold (allows nested *italic*)
    t = re.sub(r'__([^\n]+?)__', r'\1', t)           # bold (underscores, allows nested _italic_)
    t = re.sub(r'\*([^ *\n][^*\n]*)\*', r'\1', t)    # italic (space after * = list marker, not italic)
    t = re.sub(r'(?<!\w)_([^_\n]+)_(?!\w)', r'\1', t)  # italic (underscores, word-boundary safe)
    t = re.sub(r'~~([^~]+)~~', r'\1', t)          # strikethrough
    t = re.sub(r'`([^`]+)`', lambda m: m.group(1).replace('$', ''), t)  # inline code (strip $ to prevent M7 math)

    # ── M6b: Footnotes and tags ──
    # Footnote definitions: [^1]: text → (footnote: text)
    t = re.sub(r'^\[\^[^\]]+\]:\s*(.*)', r'(footnote: \1)', t, flags=re.MULTILINE)
    # Inline footnote refs: [^1] → stripped
    t = re.sub(r'\[\^[^\]]+\]', '', t)
    # Obsidian tags: #tag → stripped (but not headings — already converted by M3)
    t = re.sub(r'(?<=\s)#[a-zA-Z][\w/-]*', '', t)

    # ── M7: Math (reuse _math_to_speech) ──
    def _display_md(m):
        spoken = _math_to_speech(m.group(1))
        return ' The equation: ' + spoken + '.'
    t = re.sub(r'\$\$(.*?)\$\$', _display_md, t, flags=re.DOTALL)
    def _inline_md(m):
        return ' ' + _math_to_speech(m.group(1)) + ' '
    t = re.sub(r'\$([^\$\n]+)\$', _inline_md, t)

    # ── M8: Block elements ──
    # GFM tables (header + separator + rows).
    t = re.sub(r'(?:^\|[^\n]+\|\s*\n){2,}', 'Table omitted.\n', t, flags=re.MULTILINE)
    # Obsidian callouts: > [!note] Title\n> content → "Note: Title. content"
    def _callout(m):
        ctype = m.group(1).capitalize()
        title = m.group(2).strip() if m.group(2) else ''
        body_lines = m.group(3).split('\n') if m.group(3) else []
        body = ' '.join(l.lstrip('>').strip() for l in body_lines if l.strip())
        result = ctype + ': ' + title + '.' if title else ctype + '.'
        if body:
            result += ' ' + body
        return result
    t = re.sub(r'^>\s*\[!(\w+)\][ \t]*(.*)\n((?:^>.*\n?)*)',
               _callout, t, flags=re.MULTILINE)
    # Blockquotes (after callouts so callouts aren't treated as generic quotes).
    def _blockquote(m):
        lines = m.group(0).split('\n')
        text = ' '.join(l.lstrip('>').strip() for l in lines if l.strip())
        return 'Quote: ' + text
    t = re.sub(r'(?:^>\s?[^\n]*\n?)+', _blockquote, t, flags=re.MULTILINE)
    # Unordered lists.
    def _ulist(m):
        items = re.findall(r'^[-*+]\s+(.*)', m.group(0), re.MULTILINE)
        return ' '.join(items)
    t = re.sub(r'(?:^[-*+]\s+[^\n]+\n?)+', _ulist, t, flags=re.MULTILINE)
    # Ordered lists.
    def _olist(m):
        items = re.findall(r'^\d+\.\s+(.*)', m.group(0), re.MULTILINE)
        return ' '.join(f'{i+1}. {item}' for i, item in enumerate(items))
    t = re.sub(r'(?:^\d+\.\s+[^\n]+\n?)+', _olist, t, flags=re.MULTILINE)
    # Horizontal rules.
    t = re.sub(r'^(?:---|\*\*\*|___)\s*$', '', t, flags=re.MULTILINE)

    # ── M9: HTML tags stripped ──
    t = re.sub(r'<[^>]+>', '', t)

    # ── M10: Cleanup (preserve paragraph breaks like PDF/LaTeX front-ends) ──
    t = re.sub(r'\n{2,}', '\x00', t)
    t = re.sub(r'\n', ' ', t)
    t = t.replace('\x00', '\n\n')
    return t

# ── LaTeX front-end ──────────────────────────────────────────────

# Compiled alternations for _math_to_speech (built once at module level).
_GREEK_TEX = {
    'varepsilon':'epsilon','vartheta':'theta','varpi':'pi','varrho':'rho',
    'varsigma':'sigma','varphi':'phi',
    'alpha':'alpha','beta':'beta','gamma':'gamma','delta':'delta',
    'epsilon':'epsilon','zeta':'zeta','eta':'eta','theta':'theta',
    'iota':'iota','kappa':'kappa','lambda':'lambda','mu':'mu',
    'nu':'nu','xi':'xi','pi':'pi','rho':'rho','sigma':'sigma',
    'tau':'tau','upsilon':'upsilon','phi':'phi','chi':'chi',
    'psi':'psi','omega':'omega',
    'Gamma':'Gamma','Delta':'Delta','Theta':'Theta','Lambda':'Lambda',
    'Xi':'Xi','Pi':'Pi','Sigma':'Sigma','Upsilon':'Upsilon',
    'Phi':'Phi','Psi':'Psi','Omega':'Omega'}
_GREEK_TEX_RE = re.compile(r'\\(' + '|'.join(sorted(_GREEK_TEX, key=len, reverse=True)) + r')(?![a-zA-Z])')

_MATH_SYM = {
    'hbar':'h-bar','nabla':'del','partial':'partial',
    'infty':'infinity','pm':'plus or minus','mp':'minus or plus',
    'times':'times','cdot':'dot','cdots':'dot dot dot',
    'ldots':'dot dot dot','vdots':'vertical dots','ddots':'diagonal dots',
    'leq':'less than or equal to','geq':'greater than or equal to',
    'le':'less than or equal to','ge':'greater than or equal to',
    'neq':'not equal to','ne':'not equal to',
    'approx':'approximately','sim':'approximately',
    'simeq':'approximately equal to',
    'equiv':'equivalent to','propto':'proportional to',
    'in':'in','notin':'not in','subset':'subset of','supset':'superset of',
    'subseteq':'subset of or equal to','supseteq':'superset of or equal to',
    'cup':'union','cap':'intersection','setminus':'minus',
    'emptyset':'empty set','varnothing':'empty set',
    'forall':'for all','exists':'there exists','nexists':'there does not exist',
    'neg':'not','lnot':'not','land':'and','lor':'or',
    'rightarrow':'to','leftarrow':'from','leftrightarrow':'to and from',
    'Rightarrow':'implies','Leftarrow':'is implied by',
    'Leftrightarrow':'if and only if','iff':'if and only if',
    'mapsto':'maps to','to':'to','gets':'from',
    'uparrow':'up','downarrow':'down',
    'oplus':'direct sum','otimes':'tensor product',
    'wedge':'wedge','vee':'vee',
    'perp':'perpendicular to','parallel':'parallel to',
    'angle':'angle','triangle':'triangle',
    'therefore':'therefore','because':'because',
    'dagger':'dagger','ddagger':'double dagger',
    'ell':'l','Re':'real part of','Im':'imaginary part of'}
_MATH_SYM_RE = re.compile(r'\\(' + '|'.join(sorted(_MATH_SYM, key=len, reverse=True)) + r')(?![a-zA-Z])')

_SIZING_RE = re.compile(r'\\(?:' + '|'.join([
    'left','right','big','Big','bigg','Bigg','bigl','bigr','Bigl','Bigr',
    'biggl','biggr','displaystyle','textstyle','scriptstyle',
    'scriptscriptstyle','normalsize','small','footnotesize']) + r')(?![a-zA-Z])')

_FUNCS = ['arcsin','arccos','arctan','arccot',
          'sinh','cosh','tanh','coth',
          'sin','cos','tan','cot','sec','csc',
          'log','ln','exp','det','tr','rank','dim',
          'ker','coker','im','span','grad','div','curl']
_FUNCS_RE = re.compile(r'\\(' + '|'.join(_FUNCS) + r')(?![a-zA-Z])')

_MATHBB = {'R':'the reals','C':'the complex numbers','Z':'the integers',
           'N':'the natural numbers','Q':'the rationals'}
_MATHCAL = {'O':'big-O','L':'Lagrangian','H':'Hamiltonian'}

# siunitx data.
_SI_PREFIX_TEX = {'nano':'nano','micro':'micro','milli':'milli','kilo':'kilo',
    'mega':'mega','giga':'giga','tera':'tera','pico':'pico','femto':'femto',
    'centi':'centi','deci':'deci','hecto':'hecto'}
_SI_UNIT_TEX = {'meter':'meter','metre':'meter','gram':'gram','second':'second',
    'kelvin':'kelvin','joule':'joule','watt':'watt','hertz':'hertz',
    'newton':'newton','volt':'volt','ohm':'ohm','pascal':'pascal',
    'liter':'liter','litre':'liter','ampere':'ampere','mole':'mole',
    'candela':'candela','tesla':'tesla','farad':'farad','henry':'henry',
    'siemens':'siemens','becquerel':'becquerel','gray':'gray',
    'sievert':'sievert','weber':'weber','electronvolt':'electronvolt',
    'bar':'bar','angstrom':'angstrom','degree':'degree'}

def _math_to_speech(expr):
    """Convert LaTeX math expression to word-form English."""
    t = expr.strip()
    # Strip display delimiters.
    for p in [r'^\s*\$\$|\$\$\s*$', r'^\s*\\\[|\\\]\s*$',
              r'^\s*\\\(|\\\)\s*$', r'^\s*\$|\$\s*$']:
        t = re.sub(p, '', t)
    # Text inside math.
    t = re.sub(r'\\text(?:rm|bf|it|sf|tt)?\{([^{}]*)\}', r' \1 ', t)
    t = re.sub(r'\\operatorname\{([^{}]+)\}', r'\1', t)
    t = re.sub(r'\\mathrm\{([^{}]+)\}', r'\1', t)
    # Fractions (nested: repeat).
    for _ in range(6):
        t = re.sub(r'\\[cdt]?frac\{([^{}]*)\}\{([^{}]*)\}', r'\1 over \2', t)
    # Binomial.
    for _ in range(3):
        t = re.sub(r'\\binom\{([^{}]*)\}\{([^{}]*)\}', r'\1 choose \2', t)
    # Roots.
    t = re.sub(r'\\sqrt\[([^\]]+)\]\{([^{}]*)\}', r'\1-th root of \2', t)
    t = re.sub(r'\\sqrt\{([^{}]*)\}', r'square root of \1', t)
    t = re.sub(r'\\sqrt\s+(\w)', r'square root of \1', t)
    # Integrals.
    t = re.sub(r'\\(?:oint|iint|iiint)\b', r'\\int', t)
    t = re.sub(r'\\int\s*_\{([^{}]+)\}\s*\^\{([^{}]+)\}', r'integral from \1 to \2 of', t)
    t = re.sub(r'\\int\s*_\{([^{}]+)\}\s*\^([^{\s])', r'integral from \1 to \2 of', t)
    t = re.sub(r'\\int\s*_([^{\s])\s*\^\{([^{}]+)\}', r'integral from \1 to \2 of', t)
    t = re.sub(r'\\int\s*_([^{\s])\s*\^([^{\s])', r'integral from \1 to \2 of', t)
    t = re.sub(r'\\int\b', 'integral of', t)
    # Sums / products.
    t = re.sub(r'\\sum\s*_\{([^{}]+)\}\s*\^\{([^{}]+)\}', r'sum from \1 to \2 of', t)
    t = re.sub(r'\\sum\b', 'sum of', t)
    t = re.sub(r'\\prod\s*_\{([^{}]+)\}\s*\^\{([^{}]+)\}', r'product from \1 to \2 of', t)
    t = re.sub(r'\\prod\b', 'product of', t)
    t = re.sub(r'\\bigcup\b', 'union of', t)
    t = re.sub(r'\\bigcap\b', 'intersection of', t)
    # Limits.
    t = re.sub(r'\\arg\s*\\max\b', 'argmax', t)
    t = re.sub(r'\\arg\s*\\min\b', 'argmin', t)
    t = re.sub(r'\\lim\s*_\{([^{}]+)\}', r'limit as \1 of', t)
    t = re.sub(r'\\lim\b', 'limit', t)
    t = re.sub(r'\\sup\b', 'supremum', t)
    t = re.sub(r'\\inf\b', 'infimum', t)
    t = re.sub(r'\\max\b', 'max', t)
    t = re.sub(r'\\min\b', 'min', t)
    # Derivatives (dot notation).
    t = re.sub(r'\\dddot\{([^{}]*)\}', r'\1 triple dot', t)
    t = re.sub(r'\\ddot\{([^{}]*)\}', r'\1 double dot', t)
    t = re.sub(r'\\dot\{([^{}]*)\}', r'\1 dot', t)
    # Decorated symbols.
    t = re.sub(r'\\hat\{([^{}]*)\}', r'\1 hat', t)
    t = re.sub(r'\\bar\{([^{}]*)\}', r'\1 bar', t)
    t = re.sub(r'\\tilde\{([^{}]*)\}', r'\1 tilde', t)
    t = re.sub(r'\\vec\{([^{}]*)\}', r'vector \1', t)
    t = re.sub(r'\\overline\{([^{}]*)\}', r'\1 bar', t)
    t = re.sub(r'\\overrightarrow\{([^{}]*)\}', r'vector \1', t)
    t = re.sub(r'\\widehat\{([^{}]*)\}', r'\1 hat', t)
    t = re.sub(r'\\widetilde\{([^{}]*)\}', r'\1 tilde', t)
    t = re.sub(r'\\underbrace\{([^{}]*)\}_\{([^{}]*)\}', r'\1, that is \2,', t)
    t = re.sub(r'\\overbrace\{([^{}]*)\}', r'\1', t)
    # Matrix environments.
    def _matrix(m):
        rows = [r for r in re.split(r'\\\\', m.group(1)) if r.strip()]
        row_texts = [', '.join(c.strip() for c in row.split('&') if c.strip()) for row in rows]
        if len(row_texts) == 1:
            return 'the vector ' + row_texts[0]
        return 'the matrix with rows: ' + '; '.join(row_texts)
    t = re.sub(r'\\begin\{[pPbBvV]?matrix\*?\}(.*?)\\end\{[pPbBvV]?matrix\*?\}',
               _matrix, t, flags=re.DOTALL)
    # Cases.
    t = re.sub(r'\\begin\{cases\}(.*?)\\end\{cases\}',
               lambda m: 'cases: ' + re.sub(r'\\\\', '; ', m.group(1)).replace('&', ','),
               t, flags=re.DOTALL)
    # Sizing commands (with optional delimiter).
    t = re.sub(r'\\(?:left|right)\s*(?:\\[a-zA-Z]+|[()[\]|./])', ' ', t)
    t = _SIZING_RE.sub(' ', t)
    # Equation tags.
    t = re.sub(r'\\tag\*?\{([^{}]*)\}', r'(equation \1)', t)
    t = re.sub(r'\\(?:notag|nonumber)\b', '', t)
    # Separate adjacent single-letter variables before exponents: mc^2 -> m c^2.
    t = re.sub(r'(?<![a-zA-Z\\])([a-zA-Z])([a-zA-Z])(?=[_^])', r'\1 \2', t)
    # Superscripts.
    t = re.sub(r'\^\{2\}', ' squared', t)
    t = re.sub(r'\^\{3\}', ' cubed', t)
    t = re.sub(r'\^\{-1\}', ' inverse', t)
    t = re.sub(r'\^\{T\}', ' transpose', t)
    t = re.sub(r'\^\{\s*\\dagger\s*\}', ' dagger', t)
    t = re.sub(r'\^\{([^{}]+)\}', r' to the \1', t)
    t = re.sub(r'\^2(?![0-9])', ' squared', t)
    t = re.sub(r'\^3(?![0-9])', ' cubed', t)
    t = re.sub(r'\^([A-Za-z0-9])', r' to the \1', t)
    # Subscripts.
    t = re.sub(r'_\{([^{}]+)\}', r' sub \1', t)
    t = re.sub(r'_([A-Za-z0-9])', r' sub \1', t)
    # Greek letters (compiled alternation).
    t = _GREEK_TEX_RE.sub(lambda m: ' ' + _GREEK_TEX[m.group(1)] + ' ', t)
    # Math symbols (compiled alternation).
    t = _MATH_SYM_RE.sub(lambda m: ' ' + _MATH_SYM[m.group(1)] + ' ', t)
    # mathbb / mathcal / mathfrak / mathscr.
    t = re.sub(r'\\mathbb\{([^{}]*)\}', lambda m: _MATHBB.get(m.group(1), m.group(1)), t)
    t = re.sub(r'\\mathcal\{([^{}]*)\}', lambda m: _MATHCAL.get(m.group(1), m.group(1)), t)
    for cmd in ['mathfrak','mathscr']:
        t = re.sub(r'\\' + cmd + r'\{([^{}]*)\}', r'\1', t)
    # Standard functions (compiled alternation).
    t = _FUNCS_RE.sub(lambda m: m.group(1), t)
    # Spacing commands.
    t = re.sub(r'\\[,;:!]|\\quad\b|\\qquad\b', ' ', t)
    t = re.sub(r'\\hspace\{[^{}]*\}|\\vspace\{[^{}]*\}', ' ', t)
    # Remaining braces.
    t = re.sub(r'[{}]', '', t)
    # Operators.
    t = re.sub(r'([^<>!])=(?!=)', r'\1 equals ', t)
    t = re.sub(r'(?<![<>])\+(?!\+)', ' plus ', t)
    t = re.sub(r'(?<=\s)-(?=\s)', ' minus ', t)
    t = re.sub(r'>(?!=)', ' greater than ', t)
    t = re.sub(r'<(?!=)', ' less than ', t)
    # Function application: f(x) -> f of x.
    t = re.sub(r'\b([a-zA-Z])\(([^()]*)\)', r'\1 of \2', t)
    # Residual backslash commands.
    t = re.sub(r'\\[a-zA-Z]+', ' ', t)
    t = re.sub(r'\\[^a-zA-Z\s]', ' ', t)
    # Collapse spaces.
    t = re.sub(r' {2,}', ' ', t)
    return t.strip()

def _process_text(text):
    """Process text content within LaTeX environments (L4 text macros + L5 math only)."""
    # Inline math within text.
    def _inline(m):
        return ' ' + _math_to_speech(m.group(1)) + ' '
    text = re.sub(r'\$(.*?)\$', _inline, text)
    text = re.sub(r'\\\((.*?)\\\)', _inline, text)
    # Text formatting.
    text = re.sub(r'\\(?:textit|emph|textsl|textbf|textsc|texttt|textsf)\{([^{}]*)\}', r'\1', text)
    text = re.sub(r'\\(?:cite|citep|citet)\*?(?:\[[^\]]*\])?\{[^}]*\}', '', text)
    text = re.sub(r'\\label\{[^}]+\}', '', text)
    text = re.sub(r'~', ' ', text)
    # Residual commands (intentionally aggressive: better silent loss than garbage speech).
    text = re.sub(r'\\[a-zA-Z]+(?:\{[^{}]*\})?', ' ', text)
    text = re.sub(r'[{}]', '', text)
    text = re.sub(r' {2,}', ' ', text)
    return text.strip()

def _siunitx_expand(unit_spec, value=None):
    """Expand a siunitx unit specification to spoken words."""
    singular = value is not None and re.match(r'^1(?:\.0+)?$', value.strip())
    segments = re.split(r'\\per\b', unit_spec)
    parts = []
    for i, seg in enumerate(segments):
        # Resolve \prefix\base chains.
        words = []
        pending_prefix = ''
        for cmd in re.findall(r'\\([a-zA-Z]+)', seg):
            if cmd in _SI_PREFIX_TEX:
                pending_prefix += _SI_PREFIX_TEX[cmd]
            elif cmd in _SI_UNIT_TEX:
                unit = pending_prefix + _SI_UNIT_TEX[cmd]
                pending_prefix = ''
                if i == 0 and not singular:
                    unit += 's'
                words.append(unit)
            elif cmd == 'squared':
                if words: words[-1] += ' squared'
            elif cmd == 'cubed':
                if words: words[-1] += ' cubed'
            elif cmd == 'per':
                pass  # handled by split
            else:
                words.append(pending_prefix + cmd)
                pending_prefix = ''
        if pending_prefix:
            words.append(pending_prefix)
        part = ' '.join(words)
        parts.append(part)
    return ' per '.join(parts)

def _frontend_latex(t):
    """Convert LaTeX source into clean prose (L1-L6)."""
    import os

    # ── L1: Comment and preamble stripping ──
    t = re.sub(r'(?<!\\)%.*$', '', t, flags=re.MULTILINE)
    t = re.sub(r'^.*?\\begin\{document\}', '', t, flags=re.DOTALL)
    t = re.sub(r'\\end\{document\}.*$', '', t, flags=re.DOTALL)
    t = re.sub(r'\\(?:documentclass|usepackage|geometry|hypersetup|setlength|setcounter'
               r'|newtheorem|theoremstyle|bibliographystyle|bibliography'
               r'|DeclareMathOperator|pagestyle|thispagestyle)\b(?:\[[^\]]*\])?'
               r'\{[^}]*\}(?:\{[^}]*\})?', '', t)

    # ── L2: Custom macro expansion ──
    _macro_table = {}
    _mcache = os.path.expanduser('~/.config/speak11/latex_macros.tex')
    if os.path.isfile(_mcache):
        try:
            with open(_mcache) as f:
                _mc = f.read()
            for m in re.finditer(
                r'\\newcommand\*?\{\\([a-zA-Z]+)\}(?:\[(\d+)\])?\{((?:[^{}]|\{[^{}]*\})*)\}', _mc):
                _macro_table[m.group(1)] = (int(m.group(2)) if m.group(2) else 0, m.group(3))
            for m in re.finditer(r'\\def\\([a-zA-Z]+)\{([^{}]*)\}', _mc):
                _macro_table[m.group(1)] = (0, m.group(2))
        except Exception:
            pass
    # Collect macros from selection (override cache).
    for m in re.finditer(
        r'\\newcommand\*?\{\\([a-zA-Z]+)\}(?:\[(\d+)\])?\{((?:[^{}]|\{[^{}]*\})*)\}', t):
        _macro_table[m.group(1)] = (int(m.group(2)) if m.group(2) else 0, m.group(3))
    for m in re.finditer(r'\\def\\([a-zA-Z]+)\{([^{}]*)\}', t):
        _macro_table[m.group(1)] = (0, m.group(2))
    # Strip definitions.
    t = re.sub(r'\\(?:newcommand|renewcommand)\*?\{\\[a-zA-Z]+\}(?:\[\d+\])?\{(?:[^{}]|\{[^{}]*\})*\}', '', t)
    t = re.sub(r'\\def\\[a-zA-Z]+\{[^{}]*\}', '', t)
    # Apply macros (up to 5 rounds for chained expansion).
    for _ in range(5):
        changed = False
        for name, (nargs, body) in _macro_table.items():
            if nargs == 0:
                new_t = re.sub(r'\\' + re.escape(name) + r'(?![a-zA-Z])',
                               body.replace('\\', '\\\\'), t)
            elif nargs == 1:
                new_t = re.sub(r'\\' + re.escape(name) + r'\{([^{}]*)\}',
                               lambda m, b=body: b.replace('#1', m.group(1)), t)
            elif nargs == 2:
                new_t = re.sub(r'\\' + re.escape(name) + r'\{([^{}]*)\}\{([^{}]*)\}',
                               lambda m, b=body: b.replace('#1', m.group(1)).replace('#2', m.group(2)), t)
            else:
                continue
            if new_t != t:
                t = new_t
                changed = True
        if not changed:
            break

    # ── L3: Environment handling ──
    def _env_content(name, opt, content, label):
        return _process_text(content)
    def _env_prefixed(prefix, suffix=''):
        def handler(name, opt, content, label):
            return prefix + _process_text(content) + suffix
        return handler
    def _env_skip(msg):
        def handler(name, opt, content, label):
            return msg
        return handler
    def _restore_math_sentinels(text):
        """Restore \\x03 sentinels to \\begin{env}/\\end{env} for _math_to_speech."""
        for me in _MATH_ENVS:
            text = text.replace('\x03BEGIN_' + me + '\x03', '\\begin{' + me + '}')
            text = text.replace('\x03END_' + me + '\x03', '\\end{' + me + '}')
        return text
    def _env_equation():
        def handler(name, opt, content, label):
            spoken = _math_to_speech(_restore_math_sentinels(content))
            if label:
                return 'Equation ' + label + ': ' + spoken + '.'
            return 'The equation: ' + spoken + '.'
        return handler
    def _env_align():
        def handler(name, opt, content, label):
            lines = re.split(r'\\\\', _restore_math_sentinels(content))
            parts = []
            for line in lines:
                line = re.sub(r'&', ' ', line).strip()
                if not line:
                    continue
                parts.append(_math_to_speech(line))
            return 'The aligned equations: ' + '; '.join(parts) + '.'
        return handler
    def _env_list(numbered=False):
        def handler(name, opt, content, label):
            items = re.split(r'\\item\b\s*', content)
            items = [i.strip() for i in items if i.strip()]
            parts = []
            for idx, item in enumerate(items, 1):
                txt = _process_text(item)
                if numbered:
                    parts.append(str(idx) + '. ' + txt)
                else:
                    parts.append(txt)
            return ' '.join(parts)
        return handler
    def _env_figure():
        def handler(name, opt, content, label):
            cap_m = re.search(r'\\caption(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}', content)
            caption = _process_text(cap_m.group(1)) if cap_m else ''
            parts = ['Figure']
            if label:
                parts.append(label + ':')
            else:
                parts.append(':')
            parts.append(caption if caption else 'No caption.')
            return ' '.join(parts)
        return handler
    def _env_table():
        def handler(name, opt, content, label):
            cap_m = re.search(r'\\caption(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}', content)
            caption = _process_text(cap_m.group(1)) if cap_m else ''
            parts = ['Table']
            if label:
                parts.append(label + ':')
            else:
                parts.append(':')
            parts.append(caption if caption else 'No caption.')
            return ' '.join(parts)
        return handler
    def _env_theorem(kind):
        def handler(name, opt, content, label):
            title = kind + ' ' + opt if opt else kind
            return title + '. ' + _process_text(content)
        return handler

    _ENV = {
        'document': _env_content,
        'abstract': _env_prefixed('Abstract. '),
        'proof': _env_prefixed('Proof. ', ' End of proof.'),
        'equation': _env_equation(), 'equation*': _env_equation(),
        'align': _env_align(), 'align*': _env_align(),
        'eqnarray': _env_align(), 'eqnarray*': _env_align(),
        'multline': _env_equation(), 'multline*': _env_equation(),
        'gather': _env_align(), 'gather*': _env_align(),
        'subequations': _env_content,
        'table': _env_table(), 'table*': _env_table(),
        'tabular': _env_skip(''), 'tabularx': _env_skip(''),
        'longtable': _env_skip(''),
        'figure': _env_figure(), 'figure*': _env_figure(),
        'itemize': _env_list(), 'enumerate': _env_list(numbered=True),
        'tikzpicture': _env_skip('Diagram omitted.'),
        'pgfpicture': _env_skip('Diagram omitted.'),
        'verbatim': _env_skip('Code block omitted.'),
        'lstlisting': _env_skip('Code listing omitted.'),
        'algorithm': _env_skip('Algorithm omitted.'),
        'algorithmic': _env_skip('Algorithm omitted.'),
        'comment': _env_skip(''),
        'thebibliography': _env_skip('References omitted.'),
        'theorem': _env_theorem('Theorem'),
        'lemma': _env_theorem('Lemma'),
        'corollary': _env_theorem('Corollary'),
        'proposition': _env_theorem('Proposition'),
        'definition': _env_theorem('Definition'),
        'remark': _env_theorem('Remark'),
        'example': _env_theorem('Example'),
    }

    # Protect \$ and \& before L3 (env handlers call _process_text which has inline math regex).
    t = re.sub(r'(?<!\\)\\&', '\x01', t)
    t = re.sub(r'(?<!\\)\\\$', '\x02', t)

    # Math-internal environments: hide from L3 so _ENV_PAT can match outer
    # envs, then restore for _math_to_speech in L5.
    _MATH_ENVS = {'pmatrix','bmatrix','Bmatrix','vmatrix','Vmatrix','matrix',
                  'pmatrix*','bmatrix*','cases','smallmatrix','array'}

    # Temporarily replace \begin{pmatrix}/\end{pmatrix} with sentinels that
    # don't contain \begin{, allowing _ENV_PAT to match through them.
    for me in list(_MATH_ENVS):
        esc = re.escape(me)
        t = re.sub(r'\\begin\{' + esc + r'\}', '\x03BEGIN_' + me + '\x03', t)
        t = re.sub(r'\\end\{' + esc + r'\}', '\x03END_' + me + '\x03', t)

    _ENV_PAT = re.compile(
        r'\\begin\{([a-zA-Z*]+)\}'
        r'(?:\[([^\]]*)\])?'
        r'((?:(?!\\begin\{)[\s\S])*?)'
        r'\\end\{\1\}')

    def _replace_env(m):
        env_name = m.group(1)
        optional = (m.group(2) or '').strip()
        content = m.group(3)
        label_m = re.search(r'\\label\{([^}]+)\}', content)
        label = label_m.group(1).split(':')[-1] if label_m else ''
        content = re.sub(r'\\label\{[^}]+\}', '', content)
        handler = _ENV.get(env_name, _env_content)
        return handler(env_name, optional, content, label)

    for _ in range(10):
        new_t = _ENV_PAT.sub(_replace_env, t)
        if new_t == t:
            break
        t = new_t

    # Restore math-internal env markers for L5 _math_to_speech.
    for me in list(_MATH_ENVS):
        t = t.replace('\x03BEGIN_' + me + '\x03', '\\begin{' + me + '}')
        t = t.replace('\x03END_' + me + '\x03', '\\end{' + me + '}')

    # ── L4: Text macro expansion ──
    # Sectioning.
    t = re.sub(r'\\part\*?\{((?:[^{}]|\{[^{}]*\})*)\}', r'Part: \1. ', t)
    t = re.sub(r'\\chapter\*?\{((?:[^{}]|\{[^{}]*\})*)\}', r'Chapter: \1. ', t)
    t = re.sub(r'\\section\*?\{((?:[^{}]|\{[^{}]*\})*)\}', r'Section: \1. ', t)
    t = re.sub(r'\\subsection\*?\{((?:[^{}]|\{[^{}]*\})*)\}', r'Subsection: \1. ', t)
    t = re.sub(r'\\subsubsection\*?\{((?:[^{}]|\{[^{}]*\})*)\}', r'\1. ', t)
    t = re.sub(r'\\paragraph\*?\{((?:[^{}]|\{[^{}]*\})*)\}', r'\1. ', t)
    # Citations (silent).
    t = re.sub(r'\\cite(?:p|t|alt|alp)?\*?(?:\[[^\]]*\])?\{[^}]*\}', '', t)
    # Cross-references.
    _REF_PREFIX = {'fig':'figure','eq':'equation','tab':'table',
                   'sec':'section','alg':'algorithm','thm':'theorem',
                   'lem':'lemma','cor':'corollary','def':'definition'}
    def _ref(m):
        label = m.group(1)
        parts = label.replace('_',' ').replace('-',' ').split(':')
        if len(parts) == 2:
            return _REF_PREFIX.get(parts[0].lower(), parts[0]) + ' ' + parts[1]
        return label.replace('_',' ')
    t = re.sub(r'\\(?:ref|eqref|autoref|cref|Cref|pageref)\{([^}]+)\}', _ref, t)
    t = re.sub(r'\\label\{[^}]+\}', '', t)
    # mhchem: \ce{} -> plain formula text.
    def _ce(m):
        f = m.group(1)
        f = f.replace('->', ' to ').replace('<->', ' is in equilibrium with ')
        f = f.replace('+', ' plus ').replace('^', ' ').replace('_', '')
        return f
    t = re.sub(r'\\ce\{([^}]+)\}', _ce, t)
    # siunitx: \SI{value}{unit}, \si{unit}, \num{value}.
    def _si_handler(m):
        val = m.group(1)
        unit = m.group(2)
        # Value e-notation (use "negative N" not "-N" for unambiguous TTS).
        def _enotation(em):
            exp = em.group(2)
            if exp.startswith('-'):
                exp = 'negative ' + exp[1:]
            elif exp.startswith('+'):
                exp = exp[1:]
            return em.group(1) + ' times 10 to the ' + exp
        val = re.sub(r'(\d+\.?\d*)[eE]([+-]?\d+)', _enotation, val)
        val = val.replace('\\pm', ' plus or minus ')
        return val + ' ' + _siunitx_expand(unit, value=m.group(1))
    t = re.sub(r'\\SI\{([^}]+)\}\{([^}]+)\}', _si_handler, t)
    t = re.sub(r'\\si\{([^}]+)\}', lambda m: _siunitx_expand(m.group(1)), t)
    t = re.sub(r'\\num\{([^}]+)\}', lambda m: m.group(1).replace('\\pm', ' plus or minus '), t)
    # URLs.
    t = re.sub(r'\\url\{[^}]*\}', '', t)
    t = re.sub(r'\\href\{[^}]*\}\{([^}]*)\}', r'\1', t)
    # Footnotes.
    t = re.sub(r'\\footnote\{((?:[^{}]|\{[^{}]*\})*)\}', r' (footnote: \1) ', t)
    # Title / author.
    t = re.sub(r'\\title\{((?:[^{}]|\{[^{}]*\})*)\}', r'Title: \1. ', t)
    t = re.sub(r'\\author\{((?:[^{}]|\{[^{}]*\})*)\}', r'Authors: \1. ', t)
    # Special characters.
    # \& and \$ already protected to \x01/\x02 before L3.
    t = t.replace('\\%', ' percent ')
    t = t.replace('\\#', 'number ')
    t = t.replace('\\{', '(').replace('\\}', ')')
    t = t.replace('---', '\u2014').replace('--', '\u2013')
    t = t.replace('~', ' ')
    t = t.replace('\\ldots', '...').replace('\\dots', '...')
    # \input / \include (cannot follow).
    t = re.sub(r'\\(?:input|include|includeonly)\{[^}]+\}', '', t)
    # Text formatting.
    t = re.sub(r'\\(?:textit|emph|textsl|textbf|textsc|texttt|textsf)\{([^{}]*)\}', r'\1', t)

    # ── L5: Math to spoken English ──
    def _display(m):
        spoken = _math_to_speech(m.group(1))
        return ' The equation: ' + spoken + ' . '
    t = re.sub(r'\$\$(.*?)\$\$', _display, t, flags=re.DOTALL)
    t = re.sub(r'\\\[(.*?)\\\]', _display, t, flags=re.DOTALL)
    def _inline(m):
        return ' ' + _math_to_speech(m.group(1)) + ' '
    t = re.sub(r'\$(.*?)\$', _inline, t)
    t = re.sub(r'\\\((.*?)\\\)', _inline, t)

    # ── L6: pylatexenc for accents + residual cleanup ──
    try:
        from pylatexenc.latex2text import LatexNodes2Text
        _l2t = LatexNodes2Text(math_mode='verbatim')
        t = _l2t.latex_to_text(t)
    except Exception:
        # Fallback: common accented scientific names.
        _ACCENT_FALLBACK = {
            '\\"o':'ö', '\\"u':'ü', '\\"a':'ä', "\\'e":'é', "\\'a":'á',
            "\\'i":'í', "\\'o":'ó', "\\'u":'ú', '\\v{c}':'č', '\\v{s}':'š',
            '\\v{z}':'ž', '\\v{r}':'ř', '\\c{c}':'ç', '\\~n':'ñ', '\\~a':'ã',
            '\\^o':'ô', '\\^e':'ê', '\\^a':'â', '\\`e':'è', '\\`a':'à',
            '\\ss':'ß', '\\o':'ø', '\\O':'Ø', '\\aa':'å', '\\AA':'Å',
            '\\ae':'æ', '\\AE':'Æ', '\\l':'ł', '\\L':'Ł',
        }
        for pat, repl in _ACCENT_FALLBACK.items():
            t = t.replace(pat, repl)
    t = t.replace('\xa0', ' ')
    # Strip residual backslash commands.
    t = re.sub(r'\\[a-zA-Z]+\*?(?:\[[^\]]*\])*(?:\{[^{}]*\})*', ' ', t)
    t = re.sub(r'\\[^a-zA-Z\s]', ' ', t)
    # Remaining braces.
    t = re.sub(r'[{}]', '', t)
    # Table separators.
    t = re.sub(r'(?<!\d)&(?!\d)', ', ', t)
    # Restore protected special characters (from L4 \& and \$).
    t = t.replace('\x01', '&').replace('\x02', '$')
    # Line break handling: in LaTeX, single newlines are spaces, double are paragraphs.
    t = re.sub(r'\n{2,}', '\x00', t)
    t = re.sub(r'\n', ' ', t)
    t = t.replace('\x00', '\n\n')
    return t

# ── PDF front-end ────────────────────────────────────────────────

def _frontend_pdf(t):
    """Convert PDF-extracted text into clean prose."""
    # Encoding: fix mojibake.
    t = ftfy.fix_text(t)
    # Line endings: CRLF and stray CR to LF.
    t = t.replace('\r\n', '\n').replace('\r', '\n')
    # Invisible characters: zero-width, soft hyphens, PUA (math font garbage).
    t = re.sub(r'[\u200b\u200c\u200d\ufeff\u00ad]', '', t)
    t = re.sub(r'[\ue000-\uf8ff]', '', t)
    # Ligatures from PDF fonts: ffi/ffl before fi/fl to avoid partial match.
    t = t.replace('\ufb00','ff').replace('\ufb03','ffi').replace('\ufb04','ffl')
    t = t.replace('\ufb01','fi').replace('\ufb02','fl')
    # Unicode subscript digits to regular digits (chemistry: H₂O -> H2O).
    t = re.sub(r'[\u2080-\u2089]', lambda m: chr(ord(m.group())-0x2050), t)
    # Unicode fractions to words.
    for _f,_w in _FRAC.items():
        t = t.replace(_f, ' ' + _w + ' ')
    # Strip trailing whitespace on each line.
    t = re.sub(r'[ \t]+$', '', t, flags=re.MULTILINE)
    # Rejoin hyphenated word splits at line ends (preserve compound hyphens).
    def _hyph_check(m):
        left, right = m.group(1), m.group(2)
        if '-' in left:
            return left + '-' + right
        if left.lower() in _COMPOUND_PREFIXES:
            return left + '-' + right
        return left + right
    t = re.sub(r'(\S+)-\n(\w+)', _hyph_check, t)
    # Protect paragraph breaks (2+ newlines), rejoin the rest.
    t = re.sub(r'\n{2,}', '\x00', t)
    t = re.sub(r'(?<![.!?:\x22\x27])\n', ' ', t)
    t = t.replace('\x00', '\n\n')
    # Superscript citations copied from PDF with a space: "estimates 2 ." or "rates 1,3,5 ."
    # The space before punctuation is the telltale PDF superscript extraction artifact.
    t = re.sub(r'(?<=[a-z]) (\d{1,3}(?:\s*,\s*\d{1,3})*)(?= [.,;:?!])', '', t)
    # Glued superscript citations: forests11. → forests.
    t = re.sub(r'(?<=[a-z]{4})\d{2,3}(?=[.,;:?!)\]\s]|$)', '', t)
    # Scientific notation: 1.5 x 10^-3 spoken as full phrase.
    def _sci(m):
        raw = m.group(2)
        sign = '-' if '\u207b' in raw else ('-' if raw.startswith('-') else '')
        d = raw.replace('\u207b','').replace('-','').translate(_SD)
        try:
            e = int(sign + d)
        except ValueError:
            return m.group()
        p = m.group(1) + ' times ' if m.group(1) else ''
        return p + '10 to the ' + ('negative ' if e < 0 else '') + str(abs(e))
    t = re.sub(r'(?:(\d[\d.,]*)\s*[' + '\u00d7' + r'xX]\s*)?10([\u207b' +
        r'\u00b9\u00b2\u00b3\u2074-\u2079\u2070]+)', _sci, t)
    t = re.sub(r'(?:(\d[\d.,]*)\s*[' + '\u00d7' + r'xX]\s*)?10\^(-?\d+)',
        _sci, t)
    # Isotope notation: superscript digits before element symbol.
    def _isotope(m):
        mass = m.group(1).translate(_SD)
        sym = m.group(2)
        return _ELEM.get(sym, sym) + '-' + mass
    t = re.sub(r'(?<!\w)(' + _SUP_RE + r')([A-Z][a-z]?)\b', _isotope, t)
    # Superscript minus+digit (cm⁻¹ -> inverse, cm⁻² -> to the negative 2).
    def _neg_sup(m):
        digits = m.group()[1:].translate(_SD)  # skip leading ⁻
        n = int(digits) if digits else 1
        sp = ' ' if m.start() > 0 else ''
        if n == 1: return sp + 'inverse'
        return sp + 'to the negative ' + str(n)
    t = re.sub(r'\u207b[\xb9\xb2\xb3\u2074-\u2079\u2070]+', _neg_sup, t)
    # Remaining superscript digits -> spoken exponents.
    def _expand_sup(m):
        digits = m.group().translate(_SD)
        n = int(digits)
        if n == 2: return ' squared '
        if n == 3: return ' cubed '
        return ' to the ' + str(n) + ' '
    t = re.sub(_SUP_RE, _expand_sup, t)
    # Uncertainty notation: 2.5179(4) -> 2.5179.
    t = re.sub(r'(\d\.\d+)\(\d+\)', r'\1', t)
    # Bullet and list markers at line start.
    t = re.sub(r'^[\u2022\u2023\u25e6\u2043\u2219] +', '', t, flags=re.MULTILINE)
    t = re.sub(r'^- +', '', t, flags=re.MULTILINE)
    t = re.sub(r'^\d+[.)]\s+', '', t, flags=re.MULTILINE)
    return t

# ── Shared back-end ──────────────────────────────────────────────

def _phase0(t):
    """Phase 0: Universal typographic normalization."""
    t = t.replace('\u2212', '-')                            # minus sign
    t = t.replace('\u2026', '...')                          # ellipsis
    t = t.replace('\u201c','\x22').replace('\u201d','\x22') # smart double quotes
    t = t.replace('\u2018','\x27').replace('\u2019','\x27') # smart single quotes
    t = t.replace('\u00b7', ' ')                            # middle dot (kg-m)
    # Exotic whitespace to regular space.
    t = re.sub(r'[\u00a0\u2007\u2009\u200a\u202f\u205f]', ' ', t)
    return t

def _phaseA(t):
    """Phase A: Noise removal (URLs, DOIs, chemicals, citations)."""
    t = _CHEM_RE.sub(lambda m: _CHEM[m.group()], t)
    # URLs and DOIs.
    t = re.sub(r'https?://\S+', '', t)
    t = re.sub(r'(?i)\bdoi:\s*\S+', '', t)
    # Citation references (scientific papers).
    t = re.sub(r'(?<=[a-z]{4})\d+(?:\s*[,\u2013\u2014-]\s*\d+)+(?=[\s.,;:?!\x27\x22)\]]|$)', '', t)
    t = re.sub(r'(?<=et al\.)\d+(?:\s*[,\u2013\u2014-]\s*\d+)*', '', t)
    t = re.sub(r'\s*\[\d+(?:\s*[,;\u2013\u2014-]\s*\d+)*\]\s*', ' ', t)
    # Mid-sentence superscript citations: "study 4 that" → "study that".
    def _check_cite(m):
        prev = m.group(1).lower()
        if prev in _NUM_CONTEXT_WORDS or m.group(1).isdigit():
            return m.group(0)
        return m.group(1) + ' '
    t = _CITE_PAT.sub(_check_cite, t)
    _MONTHS = '(?:January|February|March|April|May|June|July|August|September|October|November|December)'
    t = re.sub(r'\s*\((?:(?!' + _MONTHS + r')[A-Z][a-z]+(?:\s+(?:et\s+al\.|and\s+(?!' + _MONTHS + r')[A-Z][a-z]+))?(?:,?\s*\d{4})\s*(?:;\s*(?!' + _MONTHS + r')[A-Z][a-z]+(?:\s+(?:et\s+al\.|and\s+(?!' + _MONTHS + r')[A-Z][a-z]+))?(?:,?\s*\d{4})\s*)*)\)\s*', ' ', t)
    return t

def _phaseB(t):
    """Phase B: Punctuation, abbreviations, Miller indices, arc-minute/second."""
    # Arc-minutes/seconds in DMS notation (degree-minute-second context).
    t = re.sub(r'(\d+)\u2032\s*(\d+)\u2033', r'\1 arc minutes \2 arc seconds', t)
    t = re.sub(r'(\d+\u00b0\s*)(\d+)\u2032', lambda m: m.group(1) + m.group(2) + ' arc minutes', t)
    t = t.replace('\u2032','\x27').replace('\u2033','\x22') # remaining prime / double prime
    # Miller indices: parenthesized digit groups read digit-by-digit.
    def _mill(m):
        return '(' + ' '.join(m.group(1)) + ')'
    t = re.sub(r'\(0(\d{1,2})\)', lambda m: '(' + ' '.join('0'+m.group(1)) + ')', t)
    t = re.sub(r'\b(planes?|reflections?|peaks?|indexed|facets?|diffraction|surfaces?|Miller|directions?)\s+\((\d{3})\)',
        lambda m: m.group(1) + ' (' + ' '.join(m.group(2)) + ')', t)
    t = re.sub(r'\((\d{3})\)\s+(planes?|reflections?|peaks?|indexed|facets?|diffraction|surfaces?|Miller|directions?)\b',
        lambda m: '(' + ' '.join(m.group(1)) + ') ' + m.group(2), t)
    _MILL_PAREN = r'\(\d(?:\s?\d){0,2}\)'
    def _miller_series(m):
        return re.sub(r'\((\d{1,3})\)', _mill, m.group())
    t = re.sub(_MILL_PAREN + r'(?:\s*,\s*(?:and\s+)?' + _MILL_PAREN + r'){1,}', _miller_series, t)
    # Punctuation collapse.
    t = re.sub(r'\.{4,}', '...', t)
    t = re.sub(r'\?{2,}', '?', t)
    t = re.sub(r'!{2,}', '!', t)
    # Common academic abbreviations (word-boundary safe).
    _ABBR_PL = [
      (re.compile(r'\bFigs?\.'), lambda m: 'Figures' if m.group().startswith('Figs') else 'Figure'),
      (re.compile(r'\bfigs?\.'), lambda m: 'figures' if m.group().startswith('figs') else 'figure'),
      (re.compile(r'\bEqs?\.'), lambda m: 'Equations' if m.group().startswith('Eqs') else 'Equation'),
      (re.compile(r'\beqs?\.'), lambda m: 'equations' if m.group().startswith('eqs') else 'equation'),
      (re.compile(r'\bRefs?\.'), lambda m: 'References' if m.group().startswith('Refs') else 'Reference'),
      (re.compile(r'\brefs?\.'), lambda m: 'references' if m.group().startswith('refs') else 'reference'),
      (re.compile(r'\bNo\.(?=\s*\d)'), 'Number'), (re.compile(r'\bno\.(?=\s*\d)'), 'number')]
    for _rx, _repl in _ABBR_PL:
        t = _rx.sub(_repl, t)
    _ABBR_D = {'Sect.':'Section','sect.':'section','Ch.':'Chapter','ch.':'chapter',
      'Vol.':'Volume','vol.':'volume','Suppl.':'Supplementary','suppl.':'supplementary',
      'approx.':'approximately','vs.':'versus','e.g.':'for example','i.e.':'that is',
      'et al.':'et al','etc.':'et cetera','cf.':'compare','viz.':'namely',
      'Dr.':'Doctor','Prof.':'Professor','Mr.':'Mister','Mrs.':'Misses','Ms.':'Ms',
      'Sr.':'Senior','Jr.':'Junior','St.':'Saint','Mt.':'Mount'}
    _ABBR_RE = re.compile(r'\b(' + '|'.join(re.escape(k) for k in sorted(_ABBR_D, key=len, reverse=True)) + r')')
    t = _ABBR_RE.sub(lambda m: _ABBR_D[m.group()], t)
    # Journal abbreviations.
    _JOUR = ['Nat','Commun','Phys','Rev','Lett','Proc','Natl','Acad',
      'Sci','Chem','Soc','Am','Biol','Med','Eng','Mater','Appl','Opt',
      'Mech','Res','Math','Stat','Astron','Astrophys','Geophys','Nucl',
      'Mol','Cell','Genet','Biochem','Biophys','Environ','Technol','Pharmacol']
    _J_ALT = '|'.join(_JOUR)
    # Strip periods from journal abbreviation chains (2+ in sequence).
    _JOUR_CHAIN = re.compile(r'(?:(?:' + _J_ALT + r')\.(?:\s+|$)){2,}')
    def _strip_jour(m):
        return m.group().replace('.', '')
    t = _JOUR_CHAIN.sub(_strip_jour, t)
    # Abbreviation+citation ranges.
    def _abbr_range(m):
        _PLURALS = {'Figure':'Figures','Equation':'Equations','Reference':'References',
          'Section':'Sections','Chapter':'Chapters','Number':'Numbers',
          'figure':'figures','equation':'equations','reference':'references',
          'section':'sections','chapter':'chapters','number':'numbers'}
        label = _PLURALS.get(m.group(1), m.group(1))
        return label + ' ' + m.group(2) + ' through ' + m.group(3)
    t = re.sub(r'\b(Figures?|Equations?|References?|Sections?|Chapters?|Numbers?|figures?|equations?|references?|sections?|chapters?|numbers?)\s*(\d+)\s*[-\u2013\u2014]\s*(\d+)', _abbr_range, t)
    # Numeric ranges: en-dash/em-dash between digits -> X to Y.
    t = re.sub(r'(\d[\d.,]*)\s*[\u2013\u2014]\s*(\d[\d.,]*)', r'\1 to \2', t)
    # Remaining en/em-dash (pauses, asides).
    t = re.sub(r' ?[\u2014\u2013] ?', ' -- ', t)
    t = re.sub(r' ?-{2,3} ?', ' -- ', t)
    # Math operators.
    t = re.sub(r' <= ', ' less than or equal to ', t)
    t = re.sub(r' >= ', ' greater than or equal to ', t)
    t = re.sub(r' != ', ' not equal to ', t)
    t = re.sub(r' = ', ' equals ', t)
    t = re.sub(r' << ', ' much less than ', t)
    t = re.sub(r' >> ', ' much greater than ', t)
    t = re.sub(r'\s*~(?=\s?\d)', ' approximately ', t)
    t = re.sub(r'~(?!/)', ' ', t)
    # Compound percentage forms (before bare % rule).
    _PCT = {'wt':'percent by weight','vol':'percent by volume','at':'atomic percent','mol':'mole percent'}
    t = re.sub(r'(\d+(?:\.\d+)?)\s*(wt|vol|at|mol)\s*%', lambda m: m.group(1)+' '+_PCT[m.group(2)], t)
    t = re.sub(r'(\d+(?:\.\d+)?)\s*%', r'\1 percent', t)
    # DNA prime notation.
    t = re.sub(r'\b([53])' + '\x27', r'\1 prime', t)
    return t

def _phaseC(t):
    """Phase C: Scientific symbols and units."""
    # Bra-ket notation.
    t = re.sub(r'\u27e8([^\u27e9]*)\u27e9', lambda m: m.group(1).replace('|', ' '), t)
    # Single-character symbols to spoken form.
    _SYM = {
      '\u00c5':' angstroms ', '\u212b':' angstroms ',
      '\u00b1':' plus or minus ', '\u00d7':' times ',
      '\u2248':' approximately ',
      '\u2264':' less than or equal to ','\u2265':' greater than or equal to ',
      '\u221e':' infinity ', '\u221a':' square root of ',
      '\u2192':' to ', '\u2190':' from ', '\u2194':' to and from ',
      '\u21cc':' is in equilibrium with ',
      '\u2260':' not equal to ', '\u2261':' equivalent to ',
      '\u221d':' proportional to ',
      '\u2202':' partial ', '\u2211':' sum of ', '\u220f':' product of ',
      '\u222b':' integral of ', '\u2207':' del ', '\u2205':' empty set ',
      '\u2103':' degrees Celsius ', '\u2109':' degrees Fahrenheit ',
      '\u210f':' h-bar ', '\u2113':' liters ', '\u2030':' per mille ',
      '\u2220':' angle ', '\u2225':' parallel to ',
      '\u22a5':' perpendicular to ',
      '\u2208':' in ', '\u2209':' not in ',
      '\u2282':' subset of ', '\u2283':' superset of ',
      '\u2286':' subset of ', '\u2287':' superset of ',
      '\u2229':' intersection ', '\u222a':' union ',
      '\u2234':' therefore ', '\u2235':' because ',
      '\u2200':'for all ', '\u2203':'there exists ', '\u2204':'there does not exist ',
      '\u00ac':' not ', '\u2227':' and ', '\u2228':' or ', '\u22bb':' xor ',
      '\u2295':' direct sum ', '\u2297':' tensor product ',
      '\u22c5':' dot ', '\u22c6':' star ',
      '\u2020':' dagger ', '\u2021':' double dagger ',
      '\u21d2':' implies ', '\u21d0':' is implied by ', '\u21d4':' if and only if ',
      '\u27f9':' implies ', '\u27fa':' if and only if ',
      '\u21a6':' maps to ',
      '\u2191':' up ', '\u2193':' down ', '\u2195':' up and down ',
      '\u2609':' solar '}
    for _s,_w in _SYM.items():
        t = t.replace(_s, _w)
    # Degree+letter units (must precede bare degree).
    t = re.sub(r'(?<=\d)\s*\u00b0C\b', ' degrees Celsius', t)
    t = re.sub(r'(?<=\d)\s*\u00b0F\b', ' degrees Fahrenheit', t)
    t = re.sub(r'(?<=\d)\s*\u00b0K\b', ' degrees Kelvin', t)
    t = re.sub(r'(?<=\d)\s*\u00b0(?=\s|$|[.,;:?!])', ' degrees', t)
    # Micro prefix: both µ (U+00B5 MICRO SIGN) and μ (U+03BC GREEK MU).
    _UUNIT = {'m':'meters','L':'liters','l':'liters','g':'grams','s':'seconds',
      'A':'amperes','V':'volts','W':'watts','F':'farads','H':'henrys','S':'siemens',
      'T':'teslas','Pa':'pascals','J':'joules','N':'newtons','K':'kelvins',
      'mol':'moles','Hz':'hertz','Ohm':'ohms','\u03a9':'ohms','M':'molar'}
    for _prefix in ('\u00b5', '\u03bc'):
        for _u,_w in sorted(_UUNIT.items(), key=lambda x: -len(x[0])):
            t = t.replace(_prefix+_u, 'micro'+_w)
        if _prefix in t:
            t = re.sub(re.escape(_prefix) + r'(\w)', r'micro-\1', t)
    # SI prefix+unit abbreviations after numbers.
    _SI = {'GPa':'gigapascals','MPa':'megapascals','kPa':'kilopascals','hPa':'hectopascals',
      'GHz':'gigahertz','MHz':'megahertz','kHz':'kilohertz',
      'GW':'gigawatts','MW':'megawatts','kW':'kilowatts','mW':'milliwatts',
      'MeV':'megaelectronvolts','keV':'kiloelectronvolts','GeV':'gigaelectronvolts',
      'kV':'kilovolts','mV':'millivolts',
      'mL':'milliliters','dL':'deciliters',
      'nm':'nanometers','mm':'millimeters','cm':'centimeters','km':'kilometers',
      'mg':'milligrams','kg':'kilograms','ng':'nanograms','pg':'picograms',
      'ns':'nanoseconds','ms':'milliseconds','ps':'picoseconds','fs':'femtoseconds',
      'kJ':'kilojoules','MJ':'megajoules',
      'mM':'millimolar','nM':'nanomolar','pM':'picomolar',
      'kDa':'kilodaltons','MDa':'megadaltons',
      'mA':'milliamperes',
      'TeV':'teraelectronvolts','meV':'millielectronvolts','eV':'electron volts',
      'Hz':'hertz','Pa':'pascals','dB':'decibels','mol':'moles',
      'Wb':'webers','Gy':'grays','Sv':'sieverts','Bq':'becquerels',
      'ppmv':'parts per million by volume','ppbv':'parts per billion by volume',
      'ppm':'parts per million','ppb':'parts per billion','ppt':'parts per trillion',
      'Gpc':'gigaparsecs','Mpc':'megaparsecs','kpc':'kiloparsecs','pc':'parsecs',
      'AU':'astronomical units',
      'Gbp':'gigabase pairs','Mbp':'megabase pairs','kbp':'kilobase pairs',
      'bp':'base pairs','nt':'nucleotides','Da':'daltons',
      'rpm':'revolutions per minute',
      'kcal':'kilocalories','cal':'calories',
      'atm':'atmospheres','mbar':'millibars','bar':'bars',
      'Torr':'torr','mmHg':'millimeters of mercury',
      'K':'kelvins','V':'volts','W':'watts','J':'joules',
      'L':'liters'}
    _SI_RE = re.compile(r'(?<=\d)\s*(' + '|'.join(sorted(_SI, key=len, reverse=True)) + r')\b')
    t = _SI_RE.sub(lambda m: ' ' + _SI[m.group(1)], t)
    # Unit separator: slash -> per.
    _UNIT_ENDS = sorted(set(w.split()[-1] for w in _SI.values()) |
        set('micro'+w for w in _UUNIT.values()),
        key=len, reverse=True)
    _UNIT_SINGLE = sorted({'m','s','g','A','N'}, key=len, reverse=True)
    # Multi-char units: word boundary is sufficient.
    _UNIT_SLASH_RE = re.compile(r'\b(' + '|'.join(re.escape(u) for u in _UNIT_ENDS) + r')/([a-zA-Z])')
    t = _UNIT_SLASH_RE.sub(r'\1 per \2', t)
    # Single-letter units: require preceding digit to avoid s/he, w/o, etc.
    _UNIT_SLASH_1_RE = re.compile(r'(?<=\d)(\s*)(' + '|'.join(re.escape(u) for u in _UNIT_SINGLE) + r')/([a-zA-Z])')
    t = _UNIT_SLASH_1_RE.sub(r'\1\2 per \3', t)
    # Expand denominator units after per (singular form -- "per mole" not "per moles").
    _SI_SING = {k: (v[:-1] if v.endswith('s') and v not in ('siemens',) else v)
        for k, v in _SI.items()}
    _SI_PER_RE = re.compile(r'(?<=per )(' + '|'.join(sorted(_SI, key=len, reverse=True)) + r')\b')
    t = _SI_PER_RE.sub(lambda m: _SI_SING[m.group(1)], t)
    # Ohm: number + Ω.
    t = re.sub(r'(?<=\d)\s*[\u2126\u03a9](?=\s|$|[.,;:?!)])', ' ohms', t)
    # Greek letters via unicodedata.
    _GREEK_FIX = {'lamda':'lambda'}
    def _greek(m):
        c = m.group(0)
        n = _ud.name(c, '')
        if 'GREEK' in n and 'LETTER' in n:
            # Last word before "WITH" (or last word): FINAL SIGMA -> sigma, ALPHA WITH TONOS -> alpha
            parts = n.split()
            with_idx = parts.index('WITH') if 'WITH' in parts else len(parts)
            w = parts[with_idx - 1].lower()
            return ' ' + _GREEK_FIX.get(w, w) + ' '
        return c
    t = re.sub(r'[\u0391-\u03c9]', _greek, t)
    # Greek compound fix: alpha -helix -> alpha-helix.
    _GK = 'alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega'
    t = re.sub(r'(\b(?:' + _GK + r'))\s+-\s*([a-z])', r'\1-\2', t, flags=re.IGNORECASE)
    # Roman numerals after labels.
    _R = {r: str(i) for i, r in enumerate(
        ['','I','II','III','IV','V','VI','VII','VIII','IX','X',
         'XI','XII','XIII','XIV','XV','XVI','XVII','XVIII','XIX','XX'], 0) if r}
    t = re.sub(
        r'\b(Section|Chapter|Part|Article|Item|Figure|Table|Act|Vol|No)(\s+)((?:X{0,3})(?:IX|IV|V?I{0,3}))\b',
        lambda m: m.group(1)+m.group(2)+_R.get(m.group(3),m.group(3)), t)
    # Oxidation states.
    _RV = '|'.join(sorted(_R.keys(), key=len, reverse=True))
    t = re.sub(r'\((' + _RV + r')\)', lambda m: '('+_R.get(m.group(1),m.group(1))+')', t)
    # Numbered protein complexes.
    t = re.sub(r'\b(Complex|Subunit|Chain|Type|Class)\s+(' + _RV + r')\b',
        lambda m: m.group(1)+' '+_R.get(m.group(2),m.group(2)), t)
    return t

def _phaseD(t):
    """Phase D: Final cleanup."""
    t = re.sub(r' {2,}', ' ', t)
    t = re.sub(r' +([.,;:?!)\]])', r'\1', t)
    t = re.sub(r'([\(\[]) +', r'\1', t)
    return t.strip()

# ── Main pipeline ────────────────────────────────────────────────

t = sys.stdin.read()

# Source detection.
if _is_latex(t):
    frontend = 'latex'
elif _is_markdown(t):
    frontend = 'markdown'
else:
    frontend = 'pdf'
print(f'[normalize] frontend={frontend}', file=sys.stderr)

# Front-end: convert source format to clean prose.
if frontend == 'latex':
    t = _frontend_latex(t)
elif frontend == 'markdown':
    t = _frontend_markdown(t)
elif frontend == 'pdf':
    t = _frontend_pdf(t)

# Shared back-end: source-agnostic normalization.
t = _phase0(t)
t = _phaseA(t)
t = _phaseB(t)
t = _phaseC(t)
t = _phaseD(t)

sys.stdout.write(t)
