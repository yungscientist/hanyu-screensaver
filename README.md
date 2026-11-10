# Hanyu HSK — скринсейвер для macOS

<p>
  <img src="docs/screenshots/demo-1-xiguan.png" alt="习惯 xíguàn — привыкать, привычка; HSK 3" width="49%">
  <img src="docs/screenshots/demo-2-la.png" alt="辣 là — острый; HSK 4" width="49%">
</p>

Показывает китайские слова HSK крупными иероглифами: пиньинь, до 4 русских значений из 大БКРС и пример с пиньинем и переводом. Слова идут в случайном порядке без повторов, пока не кончится колода.

## Установка

### Через Homebrew

Установите из [собственного tap `yungscientist/homebrew-tap`](https://github.com/yungscientist/homebrew-tap) (macOS 13+):

```bash
brew install --cask yungscientist/tap/hanyu-hsk
```

Если Homebrew отказывает в загрузке cask из недоверенного tap, проверьте [файл cask](https://github.com/yungscientist/homebrew-tap/blob/main/Casks/hanyu-hsk.rb) и разрешите **только этот cask**, затем повторите установку:

```bash
brew trust --cask yungscientist/tap/hanyu-hsk
brew install --cask yungscientist/tap/hanyu-hsk
```

Не требуется доверять всему tap (`brew trust yungscientist/tap`): такое разрешение охватывает и будущие формулы и cask в нём. Доверие Homebrew разрешает загрузить рецепт установки, **но не снимает карантин macOS**.

Если прежняя версия была установлена вручную из ZIP, до установки через Homebrew переместите прежний `~/Library/Screen Savers/Hanyu HSK.saver` в резервную копию (убедитесь, что файла с таким именем ещё нет):

```bash
mv "$HOME/Library/Screen Savers/Hanyu HSK.saver" "$HOME/Library/Screen Savers/Hanyu HSK.saver.backup"
```

Если прежняя версия находится в `/Library/Screen Savers` или установлена через Homebrew, не выполняйте эту команду: сначала определите способ её установки. Homebrew устанавливает новую заставку в `~/Library/Screen Savers/Hanyu HSK.saver`.

Заставка подписана ad-hoc, без Developer ID и нотаризации Apple. Homebrew не обходит Gatekeeper: если macOS блокирует заставку («не удаётся проверить разработчика»), снимите карантин **только с установленного бандла**, если доверяете этому релизу:

```bash
xattr -dr com.apple.quarantine "$HOME/Library/Screen Savers/Hanyu HSK.saver"
```

Откройте Системные настройки → Заставка и выберите «Hanyu HSK». После обновления, если macOS снова блокирует заставку, повторите команду снятия карантина для новой версии.

```bash
brew update
brew upgrade --cask yungscientist/tap/hanyu-hsk
brew uninstall --cask yungscientist/tap/hanyu-hsk
```

### Готовая сборка из ZIP (альтернатива)

1. Скачайте [Hanyu-HSK.saver.zip](https://github.com/yungscientist/hanyu-screensaver/releases/latest/download/Hanyu-HSK.saver.zip) из последнего релиза и распакуйте.
2. Снимите карантин:
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/"Hanyu HSK.saver"
   ```
   Заставка подписана ad-hoc, без Developer ID и нотаризации Apple. Поэтому macOS помечает скачанный файл карантином и отказывается его открывать («не удаётся проверить разработчика»). Команда снимает эту пометку только с этого бандла. Если распаковали не в «Загрузки», поправьте путь.
3. Дважды щёлкните `Hanyu HSK.saver` и выберите установку.

### Из исходников

Нужны Command Line Tools (`xcode-select --install`), Xcode не обязателен:

```bash
./build.sh install
```

### Настройка

Откройте Системные настройки → Заставка и выберите «Hanyu HSK». Кнопка «Параметры…» открывает настройки:

- система: HSK 2.0 (уровни 1–6) или HSK 3.0 (1–6 и 7–9);
- какие уровни показывать;
- время на слово (3–30 с, плюс 1,2 с на появление и исчезновение);
- сколько значений выводить;
- показывать ли пример;
- разные слова на каждом дисплее. По умолчанию выключено: на всех экранах одно слово, и меняется оно одновременно.

## Данные

- `Resources/words.json` — готовая база (~16 тыс. карточек), лежит внутри `.saver`.
- Переводы и примеры: ежедневный дамп 大БКРС с https://bkrs.info/p47 (`data/raw/dabkrs.gz`).
- Списки слов: HSK 2.0 — [clem109/hsk-vocabulary](https://github.com/clem109/hsk-vocabulary), HSK 3.0 — [ivankra/hsk30](https://github.com/ivankra/hsk30), официальный список 2021 года с чтениями и частями речи.

Дамп в репозиторий не входит. Чтобы пересобрать базу, скачайте `dabkrs_*.gz` со страницы выше и положите его в `data/raw/dabkrs.gz`. Нужен только Python 3, без зависимостей:

```bash
./build.sh words install
```

`tools/build_words.py` для каждого слова HSK находит статью БКРС и выбирает секции с нужным чтением и частью речи. Секции с именами собственными (фамилии, топонимы) отбрасываются, если в статье есть другие. По пометам части речи (`гл.`, `сущ.`, `прил.`…) выбирается секция, а с карточки они убираются. Значения с пометами `уст.`, `книжн.`, `диал.` и т. п. уходят в конец. Пиньинь для примеров собирается по самому БКРС: пример режется на самые длинные словарные слова.

## Отблагодарить

Если заставка помогает учить китайский, проект можно поддержать на Boosty:

[![Boosty](https://img.shields.io/badge/Boosty-support-F15F2C)](https://boosty.to/yungscientist)
