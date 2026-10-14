import { defineConfig } from 'vitest/config';

// Needs a database with the migrations and seed applied (supabase start, or
// scripts/db/test-plain.sh --keep). Set DATABASE_URL to reach it.
export default defineConfig({
  test: {
    include: ['tests/concurrency/**/*.test.ts'],
    testTimeout: 30000,
  },
});
