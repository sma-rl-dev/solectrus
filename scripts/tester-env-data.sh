#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:?command required}"
COMPOSE_FILE="${2:?compose file required}"
PROJECT_NAME="${3:?project name required}"

INFLUX_ORG="solectrus"
INFLUX_BUCKET="solectrus"
INFLUX_TOKEN="my-secret-admin-token"
SEED_START_DATE="2025-01-01"
TZ_NAME="Europe/Berlin"

compose() {
    docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" "$@"
}

expected_samples() {
    python3 - <<'PY'
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo
tz = ZoneInfo("Europe/Berlin")
start = date.fromisoformat("2025-01-01")
today = datetime.now(tz).date()
timestamps = set()
range_start = datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp()
day = start
while day <= today:
    for hour in range(24):
        local_dt = datetime.combine(day, time(hour, 0), tzinfo=tz)
        ts = int(local_dt.astimezone(timezone.utc).timestamp())
        if ts >= range_start:
            timestamps.add(ts)
    day += timedelta(days=1)
print(len(timestamps))
PY
}

expected_wallbox_samples() {
    python3 - <<'PY'
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo
tz = ZoneInfo("Europe/Berlin")
start = date.fromisoformat("2025-01-01")
today = datetime.now(tz).date()
timestamps = set()
range_start = datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp()
day = start
while day <= today:
    for hour in range(24):
        # Pinned deterministic no-point quiet window: no wallbox samples for
        # local hours 02:00-04:00 Europe/Berlin (consumer-offphase-window).
        if hour in (2, 3, 4):
            continue
        local_dt = datetime.combine(day, time(hour, 0), tzinfo=tz)
        ts = int(local_dt.astimezone(timezone.utc).timestamp())
        if ts >= range_start:
            timestamps.add(ts)
    day += timedelta(days=1)
print(len(timestamps))
PY
}

seed_settings() {
    compose exec -T dashboard bin/rails db:seed >/dev/null
    compose exec -T dashboard bin/rails runner - <<'RUBY'
Setting.plant_name = 'Sonnenhof Kirchblick 9.8 kWp'
Setting.operator_name = 'Mara Schneider'
Setting.enable_multi_inverter = false
Setting.enable_custom_consumer = true
Setting.enable_heatpump = true
Setting.enable_forecast = false
Setting.inverter_as_total = true
Setting.sensor_names = {
  inverter_power: 'Südgarage PV inverter',
  house_power: 'Farmhouse demand',
  grid_import_power: 'Grid import',
  grid_export_power: 'Grid export',
  battery_charging_power: 'Battery charging',
  battery_discharging_power: 'Battery discharge',
  battery_soc: 'Battery state of charge',
  wallbox_power: 'Courtyard EV charger',
  heatpump_power: 'Barn heat pump'
}
Setting.setup_id = 1_735_689_600
Setting.setup_token = 'tester-env-seed'
UpdateCheck.clear_cache!
RUBY
}

generate_line_protocol() {
    python3 - <<'PY'
from datetime import date, datetime, time, timedelta, timezone
from math import sin, pi
from zoneinfo import ZoneInfo

tz = ZoneInfo("Europe/Berlin")
day = date.fromisoformat("2025-01-01")
last_day = datetime.now(tz).date()

while day <= last_day:
    day_of_year = day.timetuple().tm_yday
    seasonal = 0.56 + 0.44 * sin(2 * pi * (day_of_year - 80) / 365)
    weekday = day.weekday()
    soc = 42.0 + (day_of_year % 17)

    for hour in range(24):
        local_dt = datetime.combine(day, time(hour, 0), tzinfo=tz)
        timestamp = int(local_dt.astimezone(timezone.utc).timestamp() * 1_000_000_000)

        daylight = max(0.0, sin(pi * (hour - 6) / 12))
        cloud = 0.82 + 0.12 * sin(day_of_year * 1.7 + hour * 0.6)
        inverter = round(max(0.0, 9800 * seasonal * daylight * cloud), 1)

        base_house = 430 + 35 * ((day_of_year + hour) % 5)
        morning = 480 if 6 <= hour <= 8 else 0
        evening = 760 if 18 <= hour <= 22 else 0
        kitchen = 360 if hour in (12, 13) else 0
        wallbox = 0
        if weekday in (1, 3) and 18 <= hour <= 21:
            wallbox = 3600 if hour in (19, 20) else 1800
        heatpump = 0
        if seasonal < 0.72 and (hour <= 6 or hour >= 19):
            heatpump = round(700 + (0.72 - seasonal) * 1900, 1)

        house = round(base_house + morning + evening + kitchen + wallbox + heatpump, 1)
        excess = max(0.0, inverter - house)
        deficit = max(0.0, house - inverter)
        battery_charge = round(min(2600.0, excess * 0.72), 1) if 9 <= hour <= 16 else 0.0
        battery_discharge = round(min(1800.0, deficit * 0.63), 1) if (hour <= 7 or hour >= 17) and soc > 18 else 0.0
        soc = max(12.0, min(97.0, soc + battery_charge / 5200 - battery_discharge / 4700))
        grid_export = round(max(0.0, inverter - house - battery_charge), 1)
        grid_import = round(max(0.0, house + battery_charge - inverter - battery_discharge), 1)

        print(f"inverter power={inverter} {timestamp}")
        print(f"house power={house} {timestamp}")
        print(f"grid import_power={grid_import},export_power={grid_export} {timestamp}")
        print(f"battery charging_power={battery_charge},discharging_power={battery_discharge},soc={round(soc, 1)} {timestamp}")
        # Pinned deterministic no-point quiet window (consumer-offphase-window):
        # no wallbox samples for local hours 02:00-04:00 Europe/Berlin every day,
        # so each Tue/Thu charging day pairs an active 18-21h window with an
        # overnight no-point off-phase. Daytime idle hours still write 0.0.
        if hour not in (2, 3, 4):
            print(f"wallbox power={float(wallbox)} {timestamp}")
        print(f"heatpump power={heatpump} {timestamp}")
    day += timedelta(days=1)
PY
}

seed_influx() {
    compose exec -T influxdb influx delete \
        --org "${INFLUX_ORG}" \
        --bucket "${INFLUX_BUCKET}" \
        --token "${INFLUX_TOKEN}" \
        --start 1970-01-01T00:00:00Z \
        --stop 2100-01-01T00:00:00Z >/dev/null

    generate_line_protocol | compose exec -T influxdb influx write \
        --org "${INFLUX_ORG}" \
        --bucket "${INFLUX_BUCKET}" \
        --token "${INFLUX_TOKEN}" \
        --format lp
}

seed_summaries() {
    compose exec -T dashboard bin/rails runner - <<'RUBY'
# Charts, statistics and the Insights trend comparison read daily summaries
# (summaries/summary_values) instead of raw InfluxDB points. The app builds
# those rows lazily, only for the timeframe of the page that triggers the
# build, so the previous-month Insights trend stays hidden until the year view
# has been visited. Precompute the previous month plus the current month to
# date so a freshly seeded instance renders the comparison immediately.
from = Date.current.beginning_of_month.prev_month
to = Date.current
built = Sensor::Summarizer.call(Timeframe.new("#{from}..#{to}"))
puts "Daily summaries ensured for #{from}..#{to}: #{built} day(s), #{Summary.count} summaries, #{SummaryValue.count} values"
RUBY
}

query_count() {
    local measurement="${1}"
    local field="${2}"
    compose exec -T influxdb influx query \
        --org "${INFLUX_ORG}" \
        --token "${INFLUX_TOKEN}" \
        --raw \
        "from(bucket: \"${INFLUX_BUCKET}\") |> range(start: ${SEED_START_DATE}T00:00:00Z, stop: 2100-01-01T00:00:00Z) |> filter(fn: (r) => r._measurement == \"${measurement}\" and r._field == \"${field}\") |> group() |> count(column: \"_value\")" |
        python3 -c 'import csv,sys; rows=list(csv.DictReader(line for line in sys.stdin if not line.startswith("#"))); print(rows[-1]["_value"] if rows else "0")'
}

verify_settings() {
    compose exec -T dashboard bin/rails runner - <<'RUBY'
raise 'plant_name mismatch' unless Setting.plant_name == 'Sonnenhof Kirchblick 9.8 kWp'
raise 'operator_name mismatch' unless Setting.operator_name == 'Mara Schneider'
raise 'custom consumer disabled' unless Setting.enable_custom_consumer
raise 'heatpump disabled' unless Setting.enable_heatpump
raise 'forecast enabled' if Setting.enable_forecast
raise 'registration gate enabled' if UpdateCheck.registration_grace_period_expired?
raise 'registration status mismatch' unless UpdateCheck.registration_status == 'complete'
puts 'PostgreSQL settings verified: Sonnenhof Kirchblick 9.8 kWp / Mara Schneider'
RUBY
}

verify_influx() {
    local expected expected_wallbox
    expected="$(expected_samples)"
    expected_wallbox="$(expected_wallbox_samples)"
    local sensors=(
        "inverter power"
        "house power"
        "grid import_power"
        "grid export_power"
        "battery charging_power"
        "battery discharging_power"
        "battery soc"
        "wallbox power"
        "heatpump power"
    )
    for sensor in "${sensors[@]}"; do
        local measurement="${sensor% *}"
        local field="${sensor#* }"
        local want="${expected}"
        if [[ "${sensor}" == "wallbox power" ]]; then
            want="${expected_wallbox}"
        fi
        local actual
        actual="$(query_count "${measurement}" "${field}")"
        if [[ "${actual}" != "${want}" ]]; then
            echo "InfluxDB count mismatch for ${measurement}:${field}: expected ${want}, got ${actual}" >&2
            exit 1
        fi
        echo "InfluxDB verified ${measurement}:${field} count=${actual}"
    done
}

verify_summaries() {
    compose exec -T dashboard bin/rails runner - <<'RUBY'
timeframe = Timeframe.month
trend = Insights.new(sensor: Sensor::Registry[:autarky], timeframe:).monthly_trend
raise 'monthly trend is not available for autarky' unless trend

previous_period_start = trend.base_timeframe.effective_beginning_date
first_date = trend.first_date
unless first_date && first_date <= previous_period_start
  raise "daily summaries do not cover #{previous_period_start} (earliest: #{first_date.inspect})"
end
puts "Daily summaries cover #{previous_period_start} (earliest: #{first_date})"

# The app hides month trends during the first two days of a month regardless of
# seed data (Trend#valid? guards on days_passed), so only check coverage there.
if timeframe.days_passed <= 1
  puts 'Monthly trend is hidden by the app during the first two days of the month'
else
  raise 'monthly trend is invalid' unless trend.valid?
  raise 'monthly trend has no previous-period value' if trend.base_value.nil?
  puts "Monthly autarky trend verified: #{previous_period_start}..#{trend.base_timeframe.effective_ending_date} baseline, current #{trend.current_value}, previous #{trend.base_value}"
end
RUBY
}

case "${COMMAND}" in
    seed)
        echo "==> Seeding Solectrus PostgreSQL settings..."
        seed_settings
        echo "==> Seeding deterministic hourly PV data from ${SEED_START_DATE} through today (${TZ_NAME})..."
        seed_influx
        echo "==> Precomputing daily summaries (previous month through today)..."
        seed_summaries
        echo "==> Seed complete. Run './tester-env verify' to validate counts."
        ;;
    verify)
        verify_settings
        verify_influx
        verify_summaries
        echo "Seed verification passed: expected hourly sample count per field=$(expected_samples) (wallbox=$(expected_wallbox_samples) with 02:00-04:00 quiet window omitted); daily summaries cover the previous-month trend baseline"
        ;;
    *)
        echo "Unknown data command: ${COMMAND}" >&2
        exit 1
        ;;
esac
