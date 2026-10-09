--!strict
-- Shared type definitions. Types that cross the client/server boundary
-- (remote payloads, profile schema) live here so both sides agree.

export type Profile = {
	version: number,
	coins: number,
	gems: number,
	bestHeight: number,
	totalRuns: number,
	totalCoinsEarned: number,
	upgrades: { [string]: number },
	potions: { [string]: number },
	effects: { [string]: number }, -- potion id -> seconds remaining (shield = charges)
	gear: { owned: { [string]: boolean }, equipped: string? },
	daily: { claims: number, lastDay: number },
	milestones: { [string]: boolean },
	tutorial: { step: number, firstRunDone: boolean },
	freeUpgrade: boolean,
	funnel: { [string]: boolean },
	firstJoin: number,
	lastJoinDay: number,
	quests: QuestState,
}

export type QuestProgress = { id: string, progress: number, claimed: boolean }

export type QuestState = {
	day: number,
	daily: { QuestProgress },
	week: number,
	weekly: { QuestProgress },
}

-- Extra computed state the server sends alongside the profile.
export type Snapshot = {
	profile: Profile,
	serverTime: number,
	dailyReady: boolean,
	dailyNextAt: number,
	sessionStart: number,
	playtimeClaimed: { [number]: boolean },
	inRun: boolean,
}

export type PlatformData = {
	id: number,
	kind: string,
	x: number,
	y: number,
	width: number,
	moveRange: number,
	moveSpeed: number,
	phase: number,
}

export type PickupData = {
	id: number,
	kind: string, -- "coin" | "gem" | "potion" | "capsule"
	x: number,
	y: number,
	value: number,
	potion: string?,
	risky: boolean,
}

export type HazardData = {
	id: number,
	kind: string, -- "spike" | "blackhole"
	x: number,
	y: number,
	radius: number,
	moveRange: number,
	moveSpeed: number,
	phase: number,
}

export type Chunk = {
	index: number,
	platforms: { PlatformData },
	pickups: { PickupData },
	hazards: { HazardData },
	prompts: { { y: number, text: string } },
	spine: number, -- the first `spine` platforms are the guaranteed route
}

export type RunInfo = {
	seed: number,
	origin: Vector3,
	tutorial: boolean,
	bestHeight: number,
	jumpMultiplier: number,
	airMultiplier: number,
	fuel: number,
	thrust: number,
	maxRise: number,
	hasJetpack: boolean,
	voidResistance: number,
	magnet: boolean,
	shield: number,
}

export type RunResult = {
	height: number,
	coins: number,
	gems: number,
	items: { string },
	newRecord: boolean,
	bestHeight: number,
	nextGoal: string,
	nearMiss: string?,
}

return nil
