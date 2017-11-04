Option Explicit

Const NHML="NiceHashMinerLegacy.exe"
Const maxAgeSeconds=180
Const OpenAsASCII=0 
Const CreateIfNotExist=1
Const ForAppending=8

'----- Script-wide Variables -----
Dim oFSO, oShell, CurrentFolder, LogFolder, sTempFile, sLogFile, UtilisationFailureCount, oWMI, cProcesses, Process, NHMLAge, sNiceHashCommandLine, oFile, sNiceHashFolderPath, Count, RunSilent, Miner
'----- CheckUtilisation Variables -----
Dim nVidiaSMI, QueryCount, QueryUtilisation, OutputFormat, Total, GPUDevices, GPUUtilisation, aGPUUtilisation, UtilisationAverage
'----- BuildMinerList Variables -----
Dim sLine, aNames, iIndex, aMiners()
'----- DeDupeMiners Variables -----
Dim oDictionary, aDeDupedMiners
'----- Restart NHML Variables -----
Dim fLogFile

'----- Create Objects -----
Set oFSO=CreateObject("Scripting.FileSystemObject")
Set oShell=CreateObject("WScript.Shell")

'----- Get Temp File -----
sTempFile=oFSO.GetSpecialFolder(2).ShortPath & "\" & oFSO.GetTempName
'----- Get Script Folder -----
CurrentFolder=oFSO.GetAbsolutePathName(".")
LogFolder=oFSO.BuildPath(CurrentFolder, "\Logs")
'----- If Log Sub Folder doesn't exist -----
If Not (oFSO.FolderExists(LogFolder)) Then
    '----- Create Log SubFolder-----
    oFSO.CreateFolder(LogFolder)
End If
sLogFile= oFSO.BuildPath(LogFolder, "\Monitor-NiceHash.log")

UtilisationFailureCount=0

Set oWMI=GetObject("winmgmts:\\localhost\root\CIMV2")
'----- Grab NHML Process details -----
Set cProcesses=oWMI.ExecQuery("SELECT * FROM Win32_Process WHERE Caption='" & NHML & "'")
For Each Process In cProcesses
	'----- Check NHML process age -----
	NHMLAge=DateDiff("s", WMIDateStringToDate(Process.CreationDate), Now())
	'----- Grab command line used to launch NHML -----
	sNiceHashCommandLine=Process.CommandLine
	Set oFile=oFSO.GetFile(Process.ExecutablePath)
	'----- Get NHML folder path -----
	sNiceHashFolderPath=oFSO.GetParentFolderName(oFile)
Next

'----- If NHML is older than 3 minutes -----
If NHMLAge > maxAgeSeconds Then
	'----- Check GPU Utilisation -----
	CheckUtilisation
	'----- Wait 45 seconds in case NHML has just switched algos -----
 	WScript.Sleep(45000)
 	'----- Check GPU Utilisation again -----
	CheckUtilisation
	'----- If both checks sub 80% average utilisation -----
	If UtilisationFailureCount=2 Then
		'----- Build list of miners and 3rd party miners -----
		BuildMinerList
		'----- Remove duplicates from list -----
		DeDupeMiners(aMiners)
		'----- Restart NHML -----
		RestartNHML(aDeDupedMiners)
	End If
End If

Function BuildMinerList
	Count=0
	'----- List .exe files in the NHML\bin and NHML\bin_3rdparty -----
	RunSilent=oShell.Run("%comspec% /c dir /b /s """ & sNiceHashFolderPath & "\bin\*.exe"" > " & sTempFile, 0, True)
	RunSilent=oShell.Run("%comspec% /c dir /b /s """ & sNiceHashFolderPath & "\bin_3rdparty\*.exe"" >> " & sTempFile, 0, True)

	Set oFile=oFSO.OpenTextFile(sTempFile, 1)

	'----- Read .exe file list from start to finish -----
	Do While Not oFile.AtEndOfStream
		'----- Read line -----
		sLine=oFile.ReadLine()
		'----- Split line into array using backslash as separator -----
		aNames=Split(sLine, "\")
		'----- Check last value array position -----
		iIndex=Ubound(aNames)
		'----- If .exe is in subfolder of NHML\bin or NHML\bin_3rdparty
		If iIndex > 4 Then
			'----- Extend array -----
			ReDim Preserve aMiners(Count + 1)
			'----- Add miner .exe name to array -----
			aMiners(Count)=aNames(iIndex)
			'----- Increment count -----
			Count=Count+1
		End If
	Loop
End Function

Function DeDupeMiners(aMiners)
	'----- Create a dictionary object -----
	Set oDictionary=CreateObject("Scripting.Dictionary")
	oDictionary.CompareMode=vbTextCompare
	'----- Add Miners to Dictionary (ignores duplicate names) -----
	For Each Miner in aMiners
		oDictionary(Miner)=Miner
	Next
	'----- Return DeDuped Miner List
	aDeDupedMiners=oDictionary.Items
End Function

Function RestartNHML(aDeDupedMiners)
	'----- Write event to Windows Application Log -----
	oShell.LogEvent 1, "GPU Utilisation below 80% at " & Now() & " - Restarting Nice Hash."
	Set fLogFile=oFSO.OpenTextFile(sLogFile, ForAppending, CreateIfNotExist, OpenAsASCII)
	'----- Write log to log file -----
	fLogFile.WriteLine ("GPU Utilisation below 80% at " & Now() & " - Restarting Nice Hash.")
	'----- Close log file -----
	fLogFile.Close
	'----- Kill NiceHashMinerLegacy -----
	For Each Process In cProcesses
			Process.Terminate()
	Next
	'----- Kill Miners -----
	For Each Miner in aDeDupedMiners
		Set cProcesses=oWMI.ExecQuery("SELECT * FROM Win32_Process WHERE Caption='" & Miner & "'")
		For Each Process In cProcesses
			Process.Terminate()
		Next
	Next
	'----- Wait a second for NMHL to close correctly, just in case -----
	WScript.Sleep(1000)
	'----- Run NiceNashMinerLegacy -----
	oShell.Run(sNiceHashCommandLine)
End Function

Sub CheckUtilisation
	'----- nVidia SMI query elements -----
	nVidiaSMI="""C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"""
	QueryCount=" -i 0 --query-gpu=count "
	QueryUtilisation=" --query-gpu=utilization.gpu "
	OutputFormat="--format=csv,noheader,nounits"
	
	Count=0
	Total=0

	'----- Query number of installed GPUs -----
	RunSilent=oShell.Run("cmd /c " & nVidiaSMI & QueryCount & OutputFormat & " > " & sTempFile, 0, True)
	Set oFile=oFSO.OpenTextFile(sTempFile, 1)
	'----- Read query results -----
	GPUDevices=oFile.ReadLine
	'----- Clean up results -----
	Trim(GPUDevices)
	'----- Close Temp file -----
	oFile.Close
	
	'----- Query GPU Utilisation -----
	RunSilent=oShell.Run("cmd /c " & nVidiaSMI & QueryUtilisation & OutputFormat & " > " & sTempFile, 0, True)
	
	Set oFile=oFSO.OpenTextFile(sTempFile, 1)
	'----- Read results for all GPUs into a variable -----
	GPUUtilisation=oFile.ReadAll
	'----- Clean up results -----
	Trim(GPUDevices)
	'----- Close Temp file -----
	oFile.Close
	'----- Delete Temp file -----
	oFSO.DeleteFile(sTempFile)
	
	'----- Split Utilisation results into array by line -----
	aGPUUtilisation=Split(GPUUtilisation,vbCrLf)
	'----- For each array element -----
	For Count=0 To UBound(aGPUUtilisation)-1
		'----- Clean up value -----
		aGPUUtilisation(Count)=Trim(aGPUUtilisation(Count))
		'----- Add Utilisation to running total -----
		Total=Total+Int(aGPUUtilisation(Count))
	Next
	'----- Divide running total by number of array elements -----
	UtilisationAverage=Total/UBound(aGPUUtilisation)
	'----- If utilisation is less than 80% -----
	If UtilisationAverage < 80 Then
		'----- Add 1 to utilisation failure count
		UtilisationFailureCount= UtilisationFailureCount+1
	End If
End Sub

'----- Convert Date String to Date -----
Function WMIDateStringToDate(dtmDate)
     WMIDateStringToDate=CDate(Mid(dtmDate, 7, 2) & "/" & _
     Mid(dtmDate, 5, 2) & "/" & Left(dtmDate, 4) _
     & " " & Mid (dtmDate, 9, 2) & ":" & Mid(dtmDate, 11, 2) & ":" & Mid(dtmDate,13, 2))
End Function