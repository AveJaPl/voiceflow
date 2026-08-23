-- Tryb pokoju: jedna rzecz, którą pokój wie o świecie poza ekranem.
--
-- 'together' — wszyscy siedzą w jednym pomieszczeniu, więc mikrofon jest jeden
-- na wszystkich: dwie osoby mówiące naraz nagrywają się nawzajem.
-- 'remote'   — każdy siedzi gdzie indziej, więc kolejka do mikrofonu byłaby
-- samą przeszkodą; pokój zostaje wspólną tablicą, nie blokadą.
--
-- Domyślnie 'together', bo tak zachowywały się wszystkie pokoje przed tą
-- kolumną i zmiana zachowania istniejącego pokoju musi być czyjąś decyzją.
ALTER TABLE rooms ADD COLUMN IF NOT EXISTS mode TEXT NOT NULL DEFAULT 'together';
