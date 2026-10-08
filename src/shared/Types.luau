--!strict
-- Shared type definitions. Types that cross the client/server boundary
-- (remote payloads, profile schema) live here so both sides agree.

export type PlayerProfile = {
	version: number,
	coins: number,
}

return nil
