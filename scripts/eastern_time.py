"""US Eastern timezone, with a stdlib fallback using the rules since 2007."""
from datetime import datetime, timedelta, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

HOUR = timedelta(hours=1)
STANDARD = timedelta(hours=-5)


def _boundaries(year: int) -> tuple[datetime, datetime]:
    march = datetime(year, 3, 8, 2)
    november = datetime(year, 11, 1, 2)
    return (march + timedelta(days=(6 - march.weekday()) % 7),
            november + timedelta(days=(6 - november.weekday()) % 7))


class _EasternFallback(tzinfo):
    def dst(self, dt: datetime | None) -> timedelta:
        if dt is None:
            return timedelta(0)
        start, end = _boundaries(dt.year)
        wall = dt.replace(tzinfo=None)
        if start + HOUR <= wall < end - HOUR:
            return HOUR
        if end - HOUR <= wall < end:
            return timedelta(0) if dt.fold else HOUR
        if start <= wall < start + HOUR:
            return HOUR if dt.fold else timedelta(0)
        return timedelta(0)

    def utcoffset(self, dt: datetime | None) -> timedelta:
        return STANDARD + self.dst(dt)

    def tzname(self, dt: datetime | None) -> str:
        return 'EDT' if self.dst(dt) else 'EST'

    def fromutc(self, dt: datetime) -> datetime:
        if dt.tzinfo is not self:
            raise ValueError('fromutc requires this timezone')
        start, end = _boundaries(dt.year)
        utc = dt.replace(tzinfo=None)
        # Spring switches at 07:00 UTC; autumn switches at 06:00 UTC.
        start -= STANDARD
        end -= STANDARD + HOUR
        daylight = start <= utc < end
        fold = int(end <= utc < end + HOUR)
        return (dt + STANDARD + (HOUR if daylight else timedelta(0))).replace(fold=fold)


def eastern_zone() -> tzinfo:
    """Prefer the IANA database; use current US DST rules if it is absent."""
    try:
        return ZoneInfo('America/New_York')
    except ZoneInfoNotFoundError:
        return _EasternFallback()
