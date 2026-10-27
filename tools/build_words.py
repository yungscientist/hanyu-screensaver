#!/usr/bin/env python3
"""Собирает words.json для скринсейвера: слова HSK + русские переводы из 大БКРС.

Использование:
    python3 -I tools/build_words.py data/raw/dabkrs.gz data/raw/hsk Resources/words.json

dabkrs.gz — ежедневный дамп с https://bkrs.info/p47 (формат DSL).
hsk/hsk2_N.json — HSK 2.0, уровни 1–6 (github.com/clem109/hsk-vocabulary).
hsk/hsk30.csv — официальный список HSK 3.0 (2021) с пиньинем и частью речи,
уровни 1–6 и «7–9» (github.com/ivankra/hsk30).
"""
import csv
import gzip
import json
import re
import sys
import unicodedata
from pathlib import Path

MAX_MEANINGS = 4
MAX_MEANING_LEN = 90
MAX_EXAMPLES = 2
MAX_EXAMPLE_ZH = 16
MAX_EXAMPLE_RU = 70

ARCHAIC = re.compile(r"^\*|\[p\](уст|арх|др|стар|книжн|диал|старин)\.?")
ROMAN = re.compile(r"^(?:\[b\])?\s*[IVX]+\b")
TAG = re.compile(r"\[/?[a-z*][a-z0-9]*\]")
CYR = re.compile(r"[А-Яа-яЁё]")
# часть речи из списка HSK 3.0 -> как она помечена в заголовках секций БКРС
POS_RU = {"V": "гл|связк|модальн", "N": "сущ", "Adj": "прил", "Adv": "нареч", "Conj": "союз|служебн",
          "M": "счётн", "Prep": "предлог|служебн", "Pron": "местоим", "Num": "числ",
          "Aux": "частиц|суффикс|формообр|форм\\.|служебн", "Part": "частиц|служебн", "Int": "междом", "Onom": "звукоподр"}
# явные пометы части речи; секцию с чужой пометой отбрасываем («служебное слово» бывает чем угодно — не в счёт)
POS_ANY = "гл|сущ|прил|нареч|союз|счётн|предлог|местоим|числ|частиц|междом|звукоподр"
HAN = re.compile(r"[㐀-鿿]")


def load_bkrs(path):
    """headword -> [(pinyin, body)]"""
    entries = {}
    with gzip.open(path, "rt", encoding="utf-8-sig") as f:
        head = pinyin = None
        body = []

        def flush():
            if head and body:
                entries.setdefault(head, []).append((pinyin or "", "".join(body)))

        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                continue
            if not line.strip():
                flush()
                head, pinyin, body = None, None, []
            elif not line[0].isspace():
                flush()
                head, pinyin, body = line.strip(), None, []
            elif pinyin is None:
                pinyin = line.strip()
            else:
                body.append(line.strip())
        flush()
    return entries


def norm_py(s, tones=True):
    s = s.lower().replace("’", "").replace("'", "").replace(" ", "").replace("·", "")
    s = s.replace("u:", "ü").replace("v", "ü")
    if not tones:
        s = "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")
    return s


def clean(text):
    text = TAG.sub("", text)
    text = text.replace("\\[", "[").replace("\\]", "]").replace("\\", "")
    return re.sub(r"\s+", " ", text).strip()


def split_sections(body):
    """Делит статью на секции по римским цифрам [b]I ...[/b]; возвращает [(чтение, [blocks], помета)]."""
    # Текст вне [mN]...[/m] (встречается в части статей, напр. 香蕉) считаем блоком 1-го уровня.
    blocks = []
    for m in re.finditer(r"\[m(\d)\](.*?)\[/m\]|((?:[^\[]|\[(?!m\d))+)", body):
        blocks.append((m.group(1), m.group(2)) if m.group(1) else ("1", m.group(3)))
    sections, cur = [], ("", [], "")
    for level, content in blocks:
        if clean(content).strip("-") == "":
            continue  # разделитель «-----»
        b = re.match(r"\[b\]\s*([IVX]+)\s*-?([^\[]*)\[/b\]", content)
        if level == "1" and b:
            if cur[1] or cur[0]:
                sections.append(cur)
            # чтение может стоять в том же [b] («I wèi») или отдельным [b] после пометы («I [p]частица[/p] [b]ma[/b]»)
            label = b.group(2).strip() or " ".join(
                t for t in re.findall(r"\[b\]([^\[]*)\[/b\]", content[b.end():]) if re.search(r"[a-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]", t)
            ).strip()
            cur = (label, [], clean(content[b.end():]))
            continue  # остаток заголовочного блока — пометы части речи
        if is_label(content):
            cur = (cur[0], cur[1], cur[2] + " " + clean(content))  # подзаголовки «[p]гл.[/p] [b]А[/b]»
        cur[1].append(content)
    sections.append(cur)
    return sections


def parse_example(content):
    text = clean(content)
    m = CYR.search(text)
    if not m:
        return None
    zh, ru = text[: m.start()].strip(" ,;:—-"), text[m.start():].strip()
    if re.match(r"(стар|уст|арх|диал|книжн|др|вэнь|кит\. мед|бран)\.", ru):
        return None  # пример к устаревшему/узкому значению
    if not HAN.search(zh) or len(zh) > MAX_EXAMPLE_ZH or len(ru) > MAX_EXAMPLE_RU or re.search(r"[()\[\]（）]", zh):
        return None
    return [zh, ru]


def shorten(text):
    if len(text) <= MAX_MEANING_LEN:
        return text
    cut = text[:MAX_MEANING_LEN]
    pos = max(cut.rfind(";"), cut.rfind(","))
    cut = cut[:pos] if pos > 20 else cut.rsplit(" ", 1)[0] + "…"
    # не оставляем незакрытых скобок
    depth, last_open = 0, -1
    for i, c in enumerate(cut):
        if c == "(":
            if depth == 0:
                last_open = i
            depth += 1
        elif c == ")" and depth:
            depth -= 1
    if depth and last_open > 15:
        cut = cut[:last_open]
    elif depth:
        cut += ")" * depth
    return cut.rstrip(" ,;:")


def is_label(content):
    """Блок без собственного смысла: только пометы [p], буквы-рубрики [b]А[/b] и т.п."""
    rest = re.sub(r"\[p\].*?\[/p\]|\[b\].*?\[/b\]", "", content)
    return not re.search(r"[А-Яа-яЁё]{3,}", clean(rest))


def extract(body, want=None):
    meanings, archaic, examples, old_examples, refs = [], [], [], [], []
    is_old = foreign = False
    for content in body:
        if "[ex]" in content:
            ex = parse_example(content)
            if ex and not foreign:
                (old_examples if is_old else examples).append(ex)
            continue
        # значение, помеченное другим чтением: «2) [b]lào, luò[/b] …»
        mark = re.match(r"^(?:\d+\)\s*|[а-я]\)\s*)?\[b\]([^\[А-Яа-я]*)\[/b\]", content)
        readings = [norm_py(r) for r in re.split(r"[,;]", mark.group(1)) if re.search(r"[a-zü]", norm_py(r, False))] if mark else []
        foreign = bool(want and readings and want not in readings)
        if foreign:
            continue
        if ROMAN.match(content):
            continue
        for r in re.findall(r"\[ref\](.*?)\[/ref\]", content):
            refs.append(clean(r))
        content = re.sub(r"^(\d+\)\s*|[а-я]\)\s*)?\[b\][^\[А-Яа-я]*\[/b\]\s*", r"\1", content)  # «[b]lào, luò[/b]»
        if is_label(content):
            continue
        is_old = bool(ARCHAIC.search(re.sub(r"^(\d+\)|[а-я]\))\s*", "", content)))
        text = clean(content)
        text = re.sub(r"^(\d+\)|[а-я]\))\s*", "", text).strip()
        text = re.sub(r"^(?:гл|сущ|прил)\.\s*[АБВГ]\b\s*", "", text)
        lead = re.match(r"^[-–]([^\sА-Яа-я]+)\s+", text)  # «-zhe суффикс…»
        if lead:
            if want and norm_py(lead.group(1)) != want:
                continue
            text = text[lead.end():]
        if not CYR.search(text) or text.startswith("Примечание"):
            continue
        if re.fullmatch(r"(см|то же, что)\.?\s*\S+", text):
            continue  # чистая отсылка — разрешается через refs
        (archaic if is_old else meanings).append(shorten(text))
    if not meanings:
        meanings = archaic
    examples += old_examples
    seen, uniq = set(), []
    for m in meanings:
        if m not in seen:
            seen.add(m)
            uniq.append(m)
    return uniq, examples, refs


def lookup(bkrs, word, pinyin, pos=None, depth=0):
    cands = bkrs.get(word)
    if not cands:
        return None
    want, want_nt = norm_py(pinyin), norm_py(pinyin, tones=False)

    def score(c):
        raw = re.split(r"[,;]", c[0])
        if want in [norm_py(r) for r in raw]:
            return 2
        if want_nt in [norm_py(r, tones=False) for r in raw]:
            return 1
        return 0

    cands = sorted(cands, key=score, reverse=True)
    best = [c for c in cands if score(c) == score(cands[0])]

    meanings, examples, refs = [], [], []
    for _, body in best:
        sections = split_sections(body)
        labels = lambda s: [norm_py(r) for r in re.split(r"[,;]", s[0]) if r.strip()]
        if any(s[0] for s in sections):
            # секции с нашим чтением и без пометы чтения; помеченные чужим чтением — отбрасываем
            match = [s for s in sections if s[1] and (want in labels(s) or not labels(s))]
            sections = match or sections
        # имена собственные (фамилии, топонимы) — только если больше ничего нет
        sections = [s for s in sections if "собств" not in s[2]] or sections
        pat = "|".join(POS_RU[p] for p in re.split(r"[/,]", pos or "") if p in POS_RU)
        same_pos = []
        if pat:
            same_pos = [s for s in sections if re.search(pat, s[2])]
            # секции с чужой частью речи — долой (если что-то останется)
            sections = [s for s in sections if re.search(pat, s[2]) or not re.search(POS_ANY, s[2])] or sections
        per_section = []
        for sec in sections:
            m, e, r = extract(sec[1], want)
            per_section.append((sec in same_pos, m))
            examples += e
            refs += r
        if any(hit and m for hit, m in per_section):
            # часть речи известна: подряд значения из секций этой части речи
            meanings += [x for hit, m in per_section if hit for x in m]
        else:
            # иначе по первому значению из каждой секции, затем вторые и т.д. (у 和 иначе не дойти до «и»)
            for k in range(max((len(m) for _, m in per_section), default=0)):
                meanings += [m[k] for _, m in per_section if k < len(m)]
    if not meanings and refs and depth < 2:
        for ref in refs:
            res = lookup(bkrs, ref, pinyin, pos, depth + 1)
            if res and res["m"]:
                return res
    if not meanings:
        return None
    # предпочитаем примеры, где встречается само слово, и покороче
    examples.sort(key=lambda e: (word not in e[0], not 3 <= len(e[0]) <= 10, len(e[1]) > 45))
    return {"m": meanings[:MAX_MEANINGS], "e": examples[:MAX_EXAMPLES]}


PUNCT = str.maketrans({"，": ", ", "。": ". ", "？": "? ", "！": "! ", "：": ": ", "；": "; ", "、": ", ",
                       "（": " (", "）": ") ", "“": " «", "”": "» ", "《": " «", "》": "» "})
MAX_HEAD = 6


def make_pinyin(bkrs):
    """Пиньинь для примеров: жадно режем фразу на самые длинные заголовки БКРС и берём их чтение."""
    cache = {}

    def reading(head):
        if head not in cache:
            c = bkrs.get(head)
            cache[head] = re.split(r"[,;]", c[0][0])[0].strip().lower() if c and c[0][0] else None
        return cache[head]

    def pinyin(text, word, word_py):
        out, i = [], 0
        word_py = word_py.replace(" ", "").lower()
        while i < len(text):
            if not HAN.match(text[i]):
                out.append(text[i].translate(PUNCT))
                i += 1
                continue
            if text.startswith(word, i):
                out.append(" " + word_py + " ")
                i += len(word)
                continue
            nxt = text.find(word, i + 1)
            limit = min(MAX_HEAD, len(text) - i, (nxt - i) if nxt > 0 else MAX_HEAD)
            for n in range(limit, 0, -1):
                chunk = text[i:i + n]
                if HAN.fullmatch(chunk[-1]) and (py := reading(chunk)) and (n == 1 or re.fullmatch(r"[a-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü’' ]+", py)):
                    out.append(" " + py.replace(" ", "") + " ")
                    i += n
                    break
            else:
                out.append(" ? ")
                i += 1
        return re.sub(r"\s+([,.?!:;)»])", r"\1", re.sub(r"\s+", " ", "".join(out))).strip()

    return pinyin


def plain(word):
    """«第（第二）» -> 第, «有（一）些» -> 有些, «称1» -> 称, «…极了» -> 极了"""
    word = word.split("|")[0]
    if re.match(r"^.（.*）$", word):
        return word[0]
    return re.sub(r"[（）()…\d]", "", word)


def load_hsk(hsk_dir):
    """{система: {уровень: [(слово, трад, пиньинь, часть речи)]}}; одно слово с разными чтениями — разные строки."""
    hsk2 = {}
    for lvl in range(1, 7):
        rows = json.loads((hsk_dir / f"hsk2_{lvl}.json").read_text())
        hsk2[str(lvl)] = [r for r in rows]
    hsk3, pos_of = {}, {}
    with open(hsk_dir / "hsk30.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            lvl = "7" if r["Level"] == "7-9" else r["Level"]
            word, py = plain(r["Simplified"]), re.sub(r"\s*\(.*?\)", "", r["Pinyin"].split("|")[0])
            hsk3.setdefault(lvl, []).append((word, plain(r["Traditional"]), py, r["POS"]))
            pos_of.setdefault((word, norm_py(py)), r["POS"])
    # в списке HSK 2.0 нет частей речи — берём из HSK 3.0 для того же слова с тем же чтением
    for lvl, rows in hsk2.items():
        hsk2[lvl] = [(r["hanzi"], None, r["pinyin"].replace(" ", ""), pos_of.get((r["hanzi"], norm_py(r["pinyin"]))))
                     for r in rows]
    return {"hsk2": hsk2, "hsk3": dict(sorted(hsk3.items()))}


def main(bkrs_path, hsk_dir, out_path):
    bkrs = load_bkrs(bkrs_path)
    print(f"БКРС: {len(bkrs)} заголовков", file=sys.stderr)
    pinyin = make_pinyin(bkrs)
    out = {"source": "大БКРС (bkrs.info), " + bkrs_path.name, "systems": {}}
    for system, items in load_hsk(Path(hsk_dir)).items():
        out["systems"][system] = {}
        for lvl, rows in items.items():
            words, missing = [], []
            for word, trad, py, pos in rows:
                res = lookup(bkrs, word, py, pos)
                if not res and trad and trad != word:
                    res = lookup(bkrs, trad, py, pos)
                if not res:
                    missing.append(word)
                    continue
                entry = {"w": word, "p": py, "m": res["m"]}
                if res["e"]:
                    entry["e"] = [[zh, pinyin(zh, word, py), ru] for zh, ru in res["e"]]
                words.append(entry)
            out["systems"][system][lvl] = words
            print(f"{system} {lvl}: {len(words)} слов, нет в БКРС: {len(missing)} {missing[:8]}", file=sys.stderr)
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
