-- Bailian (ADR 0003) settles from the response's usage, kept as the receipt.
ALTER TABLE budget_attempts ADD COLUMN usage TEXT;
