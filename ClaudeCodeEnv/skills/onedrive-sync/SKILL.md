---
name: onedrive-sync
description: Synchronizacja OneDrive na żądanie (~/OneDrive/Documents ↔ chmura, m.in. DAX JOURNAL MODEL - Pawel.xlsx) z raportem wyniku.
disable-model-invocation: true
---

# OneDrive sync na żądanie

Uruchom dokładnie jedno polecenie (z dowolnego katalogu):

```bash
~/.local/bin/onedrive-sync
```

Skrypt startuje usługę `onedrive-bisync.service`, tę samą co timer co 5 min: te same ustawienia, blokada i log `~/.local/state/rclone-bisync.log`. Drukuje wynik, przesłane zmiany i kopie konfliktowe.

## Raport dla użytkownika

Przekaż krótko, w tej kolejności:
1. Wynik: ✅ OK albo ❌ błąd (exit 0 / 1).
2. Przesłane zmiany z wyjścia skryptu albo „brak zmian”.
3. Jeśli jest sekcja „Konflikt”: nazwa kopii `*.conflictN.*`. To starsza wersja z chmury, a lokalna wygrała. Można ją skasować po sprawdzeniu.

## Przy błędzie

Pokaż wpisy błędów z wyjścia skryptu i zapytaj użytkownika, zanim cokolwiek naprawisz. Typowe przyczyny:
- `423 Locked`: plik otwarty w Excel Online. Zamknąć kartę i powtórzyć.
- `failed to get root` / brak sieci: powtórzyć później.

Naprawy zawsze przez usługę systemd. Ręczne `rclone bisync` (także `--resync`) omija automatyczne usuwanie pustej blokady i regułę „wersja lokalna wygrywa”.
