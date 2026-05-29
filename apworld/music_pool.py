"""Music randomizer pools.

Source-of-truth list of the audio basenames in the install's `Music/` folder,
split into two pools that shuffle within themselves when `music_randomizer` is on:

- MUSIC_POOL: the 98 long-form tracks used as level background music.
- JINGLE_POOL: the 43 short feedback cues (win/fail/found-secret/snitch horn etc.)
  kept in their own pool so a level's "you won" stinger becomes another short
  jingle, not a 3-minute orchestral piece on loop.

The client (music_patch.py) swaps the actual `Music/<name>.ogg` files on disk per
the AP seed, so every reference resolves shuffled, including the native cutscene /
menu / spell-lesson music that the old runtime NewMusicTrigger rewrite could not
touch (Pawn.PlayMusic is final native).

Edit the lists below to add or remove tracks. Basenames are exactly as they appear
in `<install>/Music/` minus the .ogg extension. vssver.scc and the 6 .flac files
that duplicate an .ogg of the same name are deliberately excluded.
"""

from __future__ import annotations


JINGLE_POOL: list[str] = [
    "Basil_cutscene_Pt3_Fawkes_eye_poke",
    "cutscene_HCC_second_place_suspense",
    "cutscene_HouseCupCeremony_intro_loop",
    "Enter-Basilisk",
    "Narration_Music_Edit2",
    "Narration_Music_Edit3",
    "Narration_Music_Edit4",
    "Opening_Castle_Fly_Through_mx",
    "Opening_Castle_Fly-through_Edit",
    "SM_CDA_DADATrapped_01",
    "SM_CDA_ShaftHitsA_01",
    "SM_CDA_ShaftHitsB_01",
    "SM_CDA_ShaftHitsC_01",
    "SM_CDA_ShaftHitsD_01",
    "SM_SCL_StealthSneak_01A",
    "SM_SCL_StealthSneak_01B",
    "SM_SCL_StealthSneak_01C",
    "SM_SCL_StealthSneak_01D",
    "SM_SCL_StealthSneak_01E",
    "sm_bur_PlayfulFail_01",
    "sm_bur_PlayfulFinish_01",
    "sm_bur_PlayfulReward_01",
    "sm_Challenge_Complete",
    "sm_cda_skurgeBlockedEdit_01_ogg",
    "sm_dia_DiagonFail_01",
    "sm_dia_DiagonReward_01",
    "sm_dia_diagonfalling",
    "sm_dueling_lose",
    "sm_dueling_win",
    "sm_ent_HousePointBad_01",
    "sm_ent_HousePointGood_01",
    "sm_ent_HousePointNeural_01",
    "sm_Ingredient_Success_Music",
    "sm_qud_snitchhorn_01",
    "sm_scl_RescueNeville_01",
    "sm_scl_StealthCaught_01",
    "sm_spb_spellbookcollect_02",
    "sm_wwa_skurgeStarEdit_01_ogg",
    "sm_wwa_willow1hit_02",
    "sm_wwa_willowLevel1Stab_01",
    "sm_wwa_willowLevel2hitp_01",
    "sm_wwa_willowLevel3Transp_01",
    "sm_wwa_willowLevel3hitp_01",
]


MUSIC_POOL: list[str] = [
    "Adv11a_endroom_action_edit",
    "Adv12Chamber_Hallway_edit",
    "Adv12Chamber_StartHall_edit",
    "Adv4Greenhouse_Music",
    "Adv8Forest_battle_music_edit",
    "Basil_cutscene_Pt1",
    "Basil_cutscene_Pt2",
    "Basil_cutscene_Pt4_dead",
    "Basil_fight_phase1",
    "Basil_fight_phase2",
    "Cutscene_Quid_Practice_Slyth_Invasion",
    "DescentToCoS",
    "DuelingBeginning_Music",
    "EntryHall_DungeonHall_music",
    "Front_End_Music",
    "Happy_Hogwarts",
    "Harry_As_Goyle",
    "HousePointsCeremony_Music",
    "Infirmary_Music_Loop",
    "Intro_Movie_Music_Edit",
    "Knockturn_Alley",
    "Music_devils_snare",
    "Music_Green_Cauldron",
    "Music_Opening_Castle_Fly-through",
    "Music_StoryBook_v2",
    "Narration_Music_Edit",
    "Peeves_chase_v2 _mx",
    "PrivetDrive2_late2school",
    "Quidditch_v2_mx",
    "SM_ARA_AragogBossOrch_01",
    "SM_CDA_DADAAction_01",
    "SM_CDA_DADACauldrons_01",
    "SM_CDA_DADACaudrons_01",
    "SM_COS_Basilisk01Orch_01",
    "SM_COS_Basilisk1-S_01",
    "SM_DIA_Knockturn_01",
    "SM_ENT_HousePointTheme_01",
    "SM_FEM_AltThemeOrch_01",
    "SM_HRY_Duelling_01",
    "SM_PRV_CoSStoryBook_01",
    "SM_QUD_Boost_01",
    "SM_SCL_StealthPOrch_01",
    "SM_SCL_StealthSneak_01_mx",
    "SM_SCL_stealthPursuitLoop",
    "SM_SLG_SlugChase_LP_v2",
    "SM_SLY_DuellingOrch_01",
    "cutscene_HouseCupCeremony_finale_loop",
    "cutscene_dumbledore_expelled",
    "cutscene_music_Turn_into_Goyle",
    "dark_hogwarts_mx",
    "fireseeds_loop_mx",
    "happy_hogwarts_mx",
    "hogwarts_neutral_mx",
    "sm_CDA_DADABuildr",
    "sm_DRC_DRACO_Theme_LP",
    "sm_bur_playful_01V2",
    "sm_bur_playful_01_loopedit",
    "sm_bur_skurgeActionEdit_01_ogg",
    "sm_bur_washing_02_V4",
    "sm_cch_CharmSpellAtmos_01",
    "sm_cch_CharmsFireCrabs_01",
    "sm_cch_charmsSpellbook_01",
    "sm_cch_charmsTense_01",
    "sm_cda_dadaShaft-S_02",
    "sm_cda_dada_cautiousEdit_01_v2",
    "sm_cda_skurgeActionEdit_02_ogg",
    "sm_cda_skurgeIntroEdit_03_ogg",
    "sm_cda_skurgeOpenEdit_01_ogg",
    "sm_ctr_GhostChamber_LP",
    "sm_dia_Ambient02_01",
    "sm_dia_AmbientLoop_01",
    "sm_dia_GambolJapesLoop_01",
    "sm_dia_diagonPlayful_01",
    "sm_dia_diagonPlayfulLoop_01",
    "sm_fem_COSE3Theme_03Mx",
    "sm_gst_DeathDay_01_LP",
    "sm_hex_GroundsNightHub_edit",
    "sm_hex_dayPursuit_02",
    "sm_hex_flying_02",
    "sm_hex_flying_action_edit",
    "sm_hex_night002-060_01",
    "sm_lib_LibraryEnter_01",
    "sm_myr_MyrtleTheme",
    "sm_qud_Snitch01",
    "sm_qud_draco",
    "sm_qud_dracor",
    "sm_scl_DayFollow_01_loop",
    "sm_scl_DayWander_01",
    "sm_SCL_neutralhwo-1-29_01",
    "sm_scl_StealthGoyle_01_loop",
    "sm_scl_StealthSearch_01",
    "sm_wwa_level2p_01",
    "sm_wwa_skurgeExploreEdit_01_ogg",
    "sm_wwa_willowBoss_01",
    "sm_wwa_willowLevel1p_01",
    "sm_wwa_willowLevel1p_01_part1",
    "sm_wwa_willowLevel1p_01_part2",
    "sm_wwa_willowLevel3_02",
]


# Tripwire: the client shuffles within each pool, so both must be non-empty and
# disjoint. Fail loudly at import rather than at patch time on a poisoned seed.
assert MUSIC_POOL, "MUSIC_POOL must not be empty"
assert JINGLE_POOL, "JINGLE_POOL must not be empty"
assert not (set(MUSIC_POOL) & set(JINGLE_POOL)), (
    "MUSIC_POOL and JINGLE_POOL must be disjoint; overlap: "
    f"{sorted(set(MUSIC_POOL) & set(JINGLE_POOL))}"
)
