"""Windows backends for voiceflow's OS-touching modules.

Every module here keeps import-time safe on non-Windows platforms (ctypes
windll and optional dependencies are loaded lazily inside functions), so the
test suite exercises the pure logic everywhere.
"""
