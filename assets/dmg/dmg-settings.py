# dmg-settings.py — раскладка окна .dmg для dmgbuild (pure-Python, без Finder).
# Пути и имена приходят через -D defines из build-dmg.sh:
#   app      — путь к WhitelistChecker.app
#   bg       — путь к фону (assets/dmg/background.png; @2x подхватится автоматически)
import os.path

app = defines.get("app", "build-mac/Build/Products/Release-maccatalyst/WhitelistChecker.app")
bg = defines.get("bg", "assets/dmg/background.png")
app_name = os.path.basename(app)

# Сжатый образ.
format = "UDZO"

# Содержимое: само приложение + ярлык на /Applications.
files = [app]
symlinks = {"Applications": "/Applications"}

# Окно: позиция на экране + размер контента (должны совпадать с make-background.swift).
window_rect = ((200, 120), (600, 400))
icon_size = 110
text_size = 12

# Фон (dmgbuild сам положит его в .background и подхватит background@2x.png для Retina).
background = bg

# Иконочный вид, без тулбара/статусбара/боковой панели.
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Позиции иконок (top-left, совпадают со стрелкой на фоне).
icon_locations = {
    app_name: (150, 205),
    "Applications": (450, 205),
}
