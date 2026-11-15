"""Пробник прунинга: что реально можно вырезать из истории и сколько это даёт.

Читает боевую базу HARNES-S и воспроизводит логику `ToolOutputPruner` на настоящих
сообщениях. Нужен для двух вещей: поставить базис перед правками R14 и проверить,
что после них отбор перестал быть пустым.

Запуск: python3 Scripts/prune_probe.py
"""

import json
import sqlite3

DB = '/Users/mb/HARNES_S_DATA/database/harness.db'
STUB = 400
# Порог пачки в токенах, как в ToolOutputPruner.batchThresholdTokens.
THRESHOLD_TOKENS = 20_000
TAIL_MESSAGES = 4


def cost(text: str) -> int:
    """Стоимость вывода так, как её видит провайдер: сериализованный JSON."""
    return len(json.dumps(text, ensure_ascii=False))


def stub(name: str, out: str, is_error: bool) -> str:
    status = 'error' if is_error else 'ok'
    first = next((ln.strip() for ln in out.split('\n') if ln.strip()), '')
    if len(first) > 120:
        first = first[:120] + '…'
    return f'[pruned: {name}, {status}, {STUB} из {len(out)} символов] {first}'


def analyze(messages, cutoff: int, threshold_tokens: int = THRESHOLD_TOKENS):
    """Кандидаты ниже cutoff, с защитой хвоста и порогом на пачку."""
    tail = '\n'.join(m[2] for m in messages[-TAIL_MESSAGES:]).lower()
    planned = {}
    seen = set()
    for mid, role, text, exchanges in messages:
        if mid >= cutoff or role != 'assistant' or not exchanges or exchanges == '[]':
            continue
        for call in json.loads(exchanges):
            out = call.get('output', '')
            if call.get('isError') or len(out) <= STUB:
                continue
            key = call.get('callID') or f'msg{mid}:call{mid}{len(planned)}'
            if key in seen:
                continue
            probe = out[:80].lower()
            if len(probe) >= 20 and probe in tail:
                continue
            replacement = stub(call.get('name', ''), out, call.get('isError', False))
            gain = cost(out) - cost(replacement)
            if gain <= 0:
                continue
            planned[key] = gain
            seen.add(key)
    saved = sum(planned.values())
    passed = saved // 4 >= threshold_tokens
    return saved, saved // 4, len(planned), passed


def main() -> None:
    rows = sqlite3.connect(DB).execute(
        'select id, role, text, exchanges from messages order by id'
    ).fetchall()
    messages = [(r[0], r[1], r[2] or '', r[3]) for r in rows]
    total = sum(len(m[3] or '') for m in messages)
    print(f'сообщений {len(messages)}, tool-выводов в базе {total} символов')
    if not messages:
        return

    top = max(m[0] for m in messages)
    print('\nсрез по окнам:')
    for low, high, label in (
        (max(0, top - 1350), max(0, top - 450), 'в промпт не попадает'),
        (max(0, top - 450), max(0, top - 300), 'выпало из окна'),
        (max(0, top - 300), top, 'уходит в промпт'),
    ):
        chars = sum(
            len(call.get('output', ''))
            for mid, _, _, ex in messages if low <= mid < high and ex and ex != '[]'
            for call in json.loads(ex)
        )
        print(f'  {low}-{high} ({label}): {chars} символов')

    print('\nкандидаты на прунинг при разных cutoff:')
    for cutoff in (max(0, top - 1350), max(0, top - 450), max(0, top - 300), top):
        chars, _, calls, _ = analyze(messages, cutoff, threshold_tokens=0)
        # Порог действует на пачку целиком: 20 000 токенов — это ~46 000 символов JSON.
        verdict = 'пачка проходит порог' if chars >= THRESHOLD_TOKENS else 'пачка порог не набирает'
        print(f'  cutoff={cutoff}: вызовов {calls}, {chars // 4} токенов ({verdict})')

    sizes = {}
    for _, _, _, ex in messages:
        if not ex or ex == '[]':
            continue
        for call in json.loads(ex):
            name = call.get('name', '?')
            sizes[name] = sizes.get(name, 0) + len(call.get('output', ''))
    worst = sorted(sizes.items(), key=lambda kv: kv[1], reverse=True)[:8]
    print('\nсамые дорогие инструменты по суммарному выводу:')
    for name, chars in worst:
        print(f'  {name}: {chars} символов')


if __name__ == '__main__':
    main()
