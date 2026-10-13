"""Explicitly selected dry-run fixture; not part of automatic test discovery."""


def test_guard_probe() -> None:
    assert sum((1, 2, 3)) == 6
