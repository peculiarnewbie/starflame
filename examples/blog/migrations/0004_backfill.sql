-- Custom migration. Add statements below; the schema snapshot doesn't change.
-- parent: fd00c3eb3746e563
-- snapshot: 5fc94c37a541d229

UPDATE "posts"
SET "slug" = lower(replace("title", ' ', '-'))
WHERE "slug" = 'pending';
