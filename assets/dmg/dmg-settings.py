# dmg-settings.py — раскладка окна .dmg для dmgbuild (pure-Python, без Finder).
# Путь к приложению приходит через -D defines из build-dmg.sh:
#   app — путь к WhitelistChecker.app
import os.path

app = defines.get("app", "build-mac/Build/Products/Release-maccatalyst/WhitelistChecker.app")
app_name = os.path.basename(app)

# Сжатый образ.
format = "UDZO"

# Содержимое: само приложение + ярлык на /Applications.
files = [app]
symlinks = {"Applications": "/Applications"}

# Окно: позиция на экране + размер контента. Без фоновой картинки.
window_rect = ((200, 120), (600, 380))
icon_size = 110
text_size = 12

# Иконочный вид, без тулбара/статусбара/боковой панели.
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Позиции иконок (top-left): по горизонтали — приложение слева, ярлык справа;
# по вертикали — выше центра окна.
icon_locations = {
    app_name: (150, 132),
    "Applications": (450, 132),
}
