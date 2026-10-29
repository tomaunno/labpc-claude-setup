"""疎通確認: OpticStudio を standalone 起動し、単レンズの RMS スポット半径を出す(MS-4 など Zemax 機)。"""
import zospy as zp
from labenv import zemax

zos, oss = zemax()
print("zemax license:", zos.Application.LicenseStatus, " version:", zos.version)
oss.new()
oss.SystemData.Aperture.ApertureValue = 10
oss.SystemData.Wavelengths.GetWavelength(1).Wavelength = 0.63
lde = oss.LDE
lde.InsertNewSurfaceAt(2)
s1, s2 = lde.GetSurfaceAt(1), lde.GetSurfaceAt(2)
s1.Radius, s1.Thickness, s1.Material = 50.0, 5.0, "N-BK7"
s2.Radius, s2.Thickness = -50.0, 48.0
mfe = oss.MFE
row = mfe.GetOperandAt(1)
row.ChangeType(zp.constants.Editors.MFE.MeritOperandType.RSCE)
mfe.CalculateMeritFunction()
print("zemax OK: RMS spot radius (um) =", round(row.Value * 1000, 3))
zos.disconnect()
