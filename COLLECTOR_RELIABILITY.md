# Vinted collector: niezawodność i obsługa

## Cel operacyjny

Live Wardrobe ma otrzymywać kompletny snapshot co 15 minut bez ręcznego pilnowania. Docelowy SLO świeżości to 99,5–99,9%; wynik mierzymy na danych z `hq_collector_runs`, a nie na samym fakcie uruchomienia harmonogramu. To cel operacyjny, nie obietnica 100% dostępności Vinted i wszystkich dostawców naraz.

## Architektura

1. Supabase Cron uruchamia Edge Function `hq-vinted-collector` co 15 minut. To główna ścieżka poboru.
2. Niezależny zegar Google Apps Script wywołuje `hq-vinted-watchdog` co 5 minut.
3. Watchdog nie uruchamia GitHuba, jeśli ostatni kompletny snapshot ma najwyżej 35 minut, collector ma aktywną dzierżawę albo awaryjne wywołanie było wysłane w ostatnich 10 minutach.
4. Po przekroczeniu progu watchdog uruchamia przez GitHub API workflow `vinted-cloud-sync.yml` w trybie `watchdog`. GitHub jest wykonawcą awaryjnym i ręcznym, ale nie jest zegarem.
5. RPC `begin_hq_collector_run` przydziela 12-minutową dzierżawę. Dzięki temu dwa wykonawcy nie zapisują snapshotu równocześnie.
6. Dopiero pełny, zweryfikowany przebieg zapisuje snapshot. Błąd HTTP, częściowa paginacja, rozbieżność referencji albo utrata dzierżawy kończy run jako `FAILED`; poprzedni kompletny snapshot pozostaje aktywny.
7. Po trzech kolejnych błędach `hq_collector_control.incident_open` przechodzi na `true`. HQ pokazuje jeden trwały incydent z licznikiem i ostatnim błędem. Sukces zamyka incydent i zeruje licznik.

## Elementy live

- główny harmonogram: `cron.job` / `hq-vinted-primary-every-15-minutes`
- główny executor: `supabase/functions/hq-vinted-collector/index.ts`
- zewnętrzny zegar: Google Apps Script `FADEWELL Vinted Watchdog`, co 5 minut
- kopia źródłowa zegara: `cloud/vinted_watchdog_apps_script.js`
- bramka watchdog: `supabase/functions/hq-vinted-watchdog/index.ts`
- wspólny resolver: `supabase/functions/_shared/vinted-resolver.ts`
- control plane: migracje `038_self_healing_vinted_collector.sql` i `039_external_vinted_watchdog.sql`
- fallback/manual executor: `.github/workflows/vinted-cloud-sync.yml` i `cloud/vinted_snapshot_sync.py`
- stan dla użytkownika: `web/operations.html` i `web/hq.js`

## Normalny przebieg

- Supabase zdobywa dzierżawę, pobiera wszystkie strony Vinted, scala stabilne przebiegi, sprawdza kompletność i zapisuje snapshot.
- Przy przejściowym 403/429/5xx, timeout albo częściowej paginacji Edge wykonuje do trzech pełnych prób z nową sesją Vinted; błędy bezpieczeństwa i 401 nie są maskowane retry.
- Co 5 minut Apps Script wywołuje watchdog. Przy świeżym snapshotcie odpowiedź brzmi `fresh`; nic więcej się nie uruchamia.
- Brak maila z GitHuba jest stanem normalnym. Workflow awaryjny jest uruchamiany wyłącznie po stwierdzeniu staleness przez watchdog albo ręcznie.

## Odzyskanie po awarii

- Jeżeli główna ścieżka nie dostarczy kompletnego snapshotu przez ponad 35 minut, najbliższy watchdog wysyła `workflow_dispatch` do GitHuba.
- Dziesięciominutowy cooldown chroni przed lawiną dispatchy. Baza zapisuje czas i ewentualny błąd ostatniego dispatchu.
- Jeżeli główny collector wróci w trakcie fallbacku, tylko pierwszy wykonawca zdobywa dzierżawę; drugi kończy bezpiecznie jako `locked`.
- Trzy kolejne niepowodzenia otwierają pojedynczy incydent w HQ. Kolejne próby aktualizują ten sam stan zamiast generować osobny incydent.
- Powrót pełnego snapshotu automatycznie zamyka incydent. Partial nigdy nie zastępuje ostatniego kompletnego snapshotu.

## Ręczne uruchomienie

W GitHub Actions wybierz `Sync Vinted Live Wardrobe` i `Run workflow`. Tryb `manual` wymusza pełny pobór i pozostaje strict. Tryb `watchdog` najpierw sprawdza świeżość i jest przeznaczony dla automatycznego fallbacku; jego błąd pozostaje warningiem, żeby nie generować maila po każdej próbie. Oba tryby respektują blokadę i kontrolę kompletności.

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

Stan zdrowy oznacza: aktywny cron, brak przeterminowanej dzierżawy, `incident_open = false`, ostatni run `SUCCESS` i `last_complete_captured_at` młodszy niż 35 minut. `last_watchdog_dispatch_error` powinien być pusty.

## Odtworzenie zewnętrznego zegara

1. Utwórz Google Apps Script i wklej `cloud/vinted_watchdog_apps_script.js`.
2. W Script Properties dodaj `WATCHDOG_SECRET` z tą samą wartością co sekret Edge Function. Nie zapisuj wartości w kodzie ani repozytorium.
3. Dodaj installable trigger dla `runWatchdog`: time-driven, minutes timer, every 5 minutes. Powiadomienia o błędach ustaw najwyżej raz dziennie.
4. Uruchom funkcję ręcznie jeden raz i zaakceptuj wymagany dostęp do zewnętrznego URL.
5. Zweryfikuj w Executions odpowiedź HTTP poniżej 300, a w bazie brak błędu dispatchu.

## Sekrety i koszt

Wartości sekretów nie trafiają do repozytorium. Supabase Edge używa sekretów Vinted, `VINTED_COLLECTOR_CRON_SECRET`, `WATCHDOG_SHARED_SECRET`, `GITHUB_WATCHDOG_TOKEN`, `GITHUB_REPO` i `GITHUB_WORKFLOW`. Vault przechowuje sekret wywołania głównego crona. Google Apps Script przechowuje wyłącznie `WATCHDOG_SECRET` w Script Properties. GitHub używa istniejących sekretów repozytorium dla Vinted i Supabase.

Układ korzysta z bezpłatnych limitów obecnych usług. Watchdog co 5 minut to około 8 640 krótkich wywołań miesięcznie; GitHub uruchamia się tylko w awarii lub ręcznie. Limity dostawców należy sprawdzić ponownie przy zmianie częstotliwości lub wolumenu.

## Pomiar i ograniczenia

Retencja `hq_collector_runs` wynosi 30 dni. Raz w tygodniu należy mierzyć udział 15-minutowych przedziałów, w których istniał kompletny snapshot młodszy niż 35 minut, liczbę uruchomień fallbacku oraz czas samoodzyskania. Sam brak otwartego incydentu nie dowodzi osiągnięcia SLO.

System usuwa pojedynczy punkt awarii zegara i executora, ale nie gwarantuje 100% dostępności Vinted, Supabase, Google i GitHuba jednocześnie. Próg 35 minut celowo dopuszcza opóźnienie jednego cyklu bez fałszywego alarmu.
