import silky
import polyworld/homes as sharedHomes
import assets

export sharedHomes except MenuImages

proc addHomeAssets*(builder: AtlasBuilder) =
  ## Keeps GotA asset selection behind its existing frontend API.
  sharedHomes.addHomeAssets(builder, MenuRoot, assets.MenuImages)
