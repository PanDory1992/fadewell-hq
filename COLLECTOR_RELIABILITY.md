# Vinted collector: niezawodność i obsługa

## Cel operacyjny

Live Wardrobe ma otrzymywać kompletny snapshot co 15 minut bez ręcznego pilnowania. Docelowy SLO świeżości to 99,5–99,9%; wynik mierzymy na danych z `hq_collector_runs`, a nie na samym fakcie uruchomienia harmonogramu.

## Architektura

1. Supabase Cron uruchamia Edge Function `hq-vinted-collector` co 15 minut. To główna ścieżka.
2. GitHub Actions uruchamia niezależny watchdog w przesuniętych minutach `7,22,37,52`.
3. Watchdog nie pobiera danych, jeśli ostatni kompletny snapshot ma najwyżej 35 minut. Po przekroczeniu progu uruchamia collector jako `GITHUB_FALLBACK`.
4. Ręczne uruchomienie workflow wymusza próbę jako `GITHUB_MANUAL`, ale nadal respektuje wspólną blokadę.
5. RPC `begin_hq_collector_run` przydziela 12-minutową dzierżawę. Dzięki temu dwa wykonawcy nie zapisują snapshotu równocześnie.
6. Dopiero pełny, zweryfikowany przebieg zapisuje snapshot. Błąd HTTP, częściowa paginacja, rozbieżność referencji albo utrata dzierżawy kończy run jako `FAILED`; poprzedni kompletny snapshot pozostaje aktywny.
7. Po trzech kolejnych błędach `hq_collector_control.incident_open` przechodzi na `true`. HQ pokazuje jeden trwały incydent z licznikiem i ostatnim błędem. Sukces zamyka incydent i zeruje licznik.

## Elementy live

- harmonogram: `cron.job` / `hq-vinted-primary-every-15-minutes`
- główny executor: `supabase/functions/hq-vinted-collector/index.ts`
- wspólny resolver: `supabase/functions/_shared/vinted-resolver.ts`
- control plane: migracja `038_self_healing_vinted_collector.sql`
- watchdog/fallback: `.github/workflows/vinted-cloud-sync.yml`
- wykonawca GitHub: `cloud/vinted_snapshot_sync.py`
- stan dla użytkownika: `web/operations.html` i `web/hq.js`

## Normalny przebieg

- Supabase zdobywa dzierżawę, pobiera wszystkie strony Vinted, scala stabilne przebiegi, sprawdza kompletność i zapisuje snapshot.
- GitHub watchdog widzi świeży snapshot i kończy się sukcesem bez uruchamiania collectora.
- Brak maila z GitHuba jest stanem normalnym.

## Odzyskanie po awarii

- Jeśli główna ścieżka nie dostarczy kompletnego snapshotu przez ponad 35 minut, najbliższy watchdog próbuje fallbacku.
- Jeśli główny collector wróci w trakcie fallbacku, tylko pierwszy wykonawca zdobywa dzierżawę; drugi kończy bezpiecznie jako `locked`.
- Trzy kolejne niepowodzenia otwierają pojedynczy incydent w HQ. Kolejne próby aktualizują ten sam stan zamiast generować osobny incydent.

## Ręczne uruchomienie

W GitHub Actions wybierz `Sync Vinted Live Wardrobe` i `Run workflow`. To ścieżka awaryjna; nie omija blokady ani kontroli kompletności.

## Kontrola stanu

```sql
select * from public.hq_collector_control where collector_key = 'vinted_live';

select source, status, started_at, completed_at, captured_at, item_count, error
from public.hq_collector_runs
where collector_key = 'vinted_live'
order by started_at desc
limit 30;

select jobid, jobname, schedule, active
from cron.job
where jobname = 'hq-vinted-primary-every-15-minutes';
```

Stan zdrowy oznacza: aktywny cron, brak przeterminowanej dzierżawy, `incident_open = false`, ostatni run `SUCCESS` i `last_complete_captured_at` młodszy niż 35 minut.

## Sekrety i utrzymanie

Wartości sekretów nie trafiają do repozytorium. Supabase Edge używa `VINTED_ACCESS_TOKEN`, `VINTED_COOKIE`, `VINTED_USER_ID` i `VINTED_COLLECTOR_CRON_SECRET`; Vault przechowuje sekret wywołania crona. GitHub używa istniejących sekretów repozytorium dla Vinted i Supabase.

Retencja `hq_collector_runs` wynosi 30 dni. Raz w tygodniu warto sprawdzać SLO: udział 15-minutowych przedziałów, w których istniał kompletny snapshot młodszy niż 35 minut, oraz liczbę uruchomień fallbacku. Sam brak otwartego incydentu nie dowodzi osiągnięcia SLO.

## Ograniczenia

System sam odzyskuje się po awarii pojedynczego harmonogramu lub executora, ale nie gwarantuje 100% dostępności Vinted, Supabase i GitHuba jednocześnie. Próg 35 minut celowo dopuszcza opóźnienie jednego cyklu bez fałszywego alarmu.
