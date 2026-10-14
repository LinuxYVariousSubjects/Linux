#!/bin/bash
# Instaluje skill /onedrive-sync i polecenie `onedrive-sync` jako symlinki do tego folderu,
# więc `git pull` je aktualizuje. Wymaga usługi onedrive-bisync.service (patrz onedrive-sync-lesson.md).
set -euo pipefail

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Poza ~/.claude/skills i PATH: kopia w skills byłaby wczytana jako drugi skill onedrive-sync
backup="$HOME/.local/state/onedrive-sync-backup/$(date +%Y%m%d%H%M%S)"

# Istniejący zwykły plik/katalog (nie symlink) odkłada na bok zamiast go nadpisać
link() {
    local target=$1 dst=$2 kind=$3
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        mkdir -p "$backup/$kind"
        mv "$dst" "$backup/$kind/"
        echo "Kopia zapasowa: $backup/$kind/$(basename "$dst")"
    fi
    ln -sfn "$target" "$dst"
    echo "Link: $dst -> $target"
}

mkdir -p "$HOME/.claude/skills" "$HOME/.local/bin"
link "$src" "$HOME/.claude/skills/onedrive-sync" skills
link "$src/onedrive-sync" "$HOME/.local/bin/onedrive-sync" bin

systemctl --user cat onedrive-bisync.service >/dev/null 2>&1 \
    || echo "Uwaga: brak onedrive-bisync.service, więc onedrive-sync nie zadziała (patrz onedrive-sync-lesson.md)."
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "Uwaga: ~/.local/bin nie jest w PATH." ;;
esac
