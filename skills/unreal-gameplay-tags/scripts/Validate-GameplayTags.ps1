#Requires -Version 5.1
<#
.SYNOPSIS
	扫描 Unreal 项目的 GameplayTag 声明，按 unreal-gameplay-tags 规范输出违规报告。只读、零副作用。

.DESCRIPTION
	扫描源：
	  - <ProjectRoot>/Config/DefaultGameplayTags.ini
	  - <ProjectRoot>/Config/Tags/**/*.ini        （递归；引擎固定搜索路径）
	  - <ProjectRoot>/Source/**/*.{h,cpp}
	  - <ProjectRoot>/Plugins/**/Source/**/*.{h,cpp}   （可用 -SkipPlugins 关闭）

	检查项见 references/governance.md「校验脚本」。

.PARAMETER ProjectRoot
	Unreal 项目根目录（含 .uproject 的那一层）。

.PARAMETER Namespace
	期望的根命名空间（tag 首段）。留空则不检查首段。

.PARAMETER MaxDepth
	段数上限，默认 4。

.PARAMETER ProbeDomain
	允许作为顶层域的生命周期类域名，默认 Probe。该名出现在段 1 时不算违规，出现在段 2 及之后算违规。

.PARAMETER ForbiddenSegments
	不得作为层级段的词（生命周期/阶段类）。默认见参数声明。

.PARAMETER SkipPlugins
	不扫描 Plugins 目录。

.PARAMETER SkipNativeScan
	不扫描 C++ 原生声明。

.EXAMPLE
	pwsh -File Validate-GameplayTags.ps1 -ProjectRoot E:\Projects_Dev\MyGame -Namespace Tcs

.NOTES
	退出码：0 = 无 Error；1 = 有 Error；2 = 参数或路径问题。
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, Position = 0)]
	[string]$ProjectRoot,

	[string]$Namespace = '',

	[int]$MaxDepth = 4,

	[string]$ProbeDomain = 'Probe',

	[string[]]$ForbiddenSegments = @('Probe', 'Temp', 'Tmp', 'WIP', 'Debug', 'Deprecated', 'Obsolete', 'Draft'),

	[switch]$SkipPlugins,

	[switch]$SkipNativeScan
)

$ErrorActionPreference = 'Stop'

# 与 AGENTS.md「项目初始化排除项」一致
$ExcludedDirNames = @('.git', '.idea', '.vs', '.vscode', 'Binaries', 'Build', 'Intermediate', 'Saved', 'DerivedDataCache')

$script:Issues = New-Object System.Collections.Generic.List[object]

function Add-Issue
{
	param(
		[ValidateSet('Error', 'Warning', 'Info')]
		[string]$Level,
		[string]$Check,
		[string]$Tag,
		[string]$Detail,
		[string]$Location
	)

	$script:Issues.Add([pscustomobject]@{
			Level    = $Level
			Check    = $Check
			Tag      = $Tag
			Detail   = $Detail
			Location = $Location
		})
}

function Test-ExcludedPath
{
	param([string]$Path)

	foreach ($segment in ($Path -split '[\\/]'))
	{
		if ($ExcludedDirNames -contains $segment)
		{
			return $true
		}
	}

	return $false
}

function Get-RelativePath
{
	param([string]$Base, [string]$Path)

	if ($Path.StartsWith($Base, [System.StringComparison]::OrdinalIgnoreCase))
	{
		return $Path.Substring($Base.Length).TrimStart('\', '/')
	}

	return $Path
}

# 常量名与 tag 文本的对应判据：去掉前导 Tag 与全部分隔符后应逐字相等
function Get-NormalizedTagToken
{
	param([string]$Text)

	$normalized = $Text.ToLowerInvariant() -replace '[._\-]', ''

	if ($normalized.StartsWith('tag'))
	{
		$normalized = $normalized.Substring(3)
	}

	return $normalized
}

# ---------------------------------------------------------------- 参数校验

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container))
{
	Write-Error "ProjectRoot 不存在或不是目录：$ProjectRoot"
	exit 2
}

$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Config')))
{
	Write-Warning "未找到 Config 目录：$ProjectRoot\Config（继续，仅扫描 C++）"
}

# ---------------------------------------------------------------- 采集：ini 词表

$TagRecords = New-Object System.Collections.Generic.List[object]

$IniFiles = New-Object System.Collections.Generic.List[string]

$DefaultIni = Join-Path $ProjectRoot 'Config\DefaultGameplayTags.ini'
if (Test-Path -LiteralPath $DefaultIni)
{
	$IniFiles.Add($DefaultIni)
}

$TagsDir = Join-Path $ProjectRoot 'Config\Tags'
if (Test-Path -LiteralPath $TagsDir)
{
	Get-ChildItem -LiteralPath $TagsDir -Recurse -Filter '*.ini' -File |
		Where-Object { -not (Test-ExcludedPath $_.FullName) } |
		ForEach-Object { $IniFiles.Add($_.FullName) }
}

foreach ($iniFile in $IniFiles)
{
	$lineNumber = 0

	foreach ($line in (Get-Content -LiteralPath $iniFile -Encoding UTF8))
	{
		$lineNumber++

		$entryMatch = [regex]::Match($line, '^\s*\+GameplayTagList\s*=\s*\((.*)\)\s*$')
		if (-not $entryMatch.Success)
		{
			continue
		}

		$body = $entryMatch.Groups[1].Value

		$tagMatch = [regex]::Match($body, 'Tag\s*=\s*"([^"]*)"')
		if (-not $tagMatch.Success)
		{
			continue
		}

		$commentMatch = [regex]::Match($body, 'DevComment\s*=\s*"([^"]*)"')

		$TagRecords.Add([pscustomobject]@{
				Tag            = $tagMatch.Groups[1].Value
				Source         = 'ini'
				Comment        = $(if ($commentMatch.Success) { $commentMatch.Groups[1].Value } else { '' })
				ConstantName   = ''
				HasExportMacro = $false
				Location       = "$(Get-RelativePath $ProjectRoot $iniFile):$lineNumber"
			})
	}
}

# ---------------------------------------------------------------- 采集：C++ 原生 tag

$HeaderDeclarations = @{}

if (-not $SkipNativeScan)
{
	$SourceDirs = New-Object System.Collections.Generic.List[string]

	$ProjectSourceDir = Join-Path $ProjectRoot 'Source'
	if (Test-Path -LiteralPath $ProjectSourceDir)
	{
		$SourceDirs.Add($ProjectSourceDir)
	}

	if (-not $SkipPlugins)
	{
		$PluginsDir = Join-Path $ProjectRoot 'Plugins'
		if (Test-Path -LiteralPath $PluginsDir)
		{
			Get-ChildItem -LiteralPath $PluginsDir -Recurse -Directory -Filter 'Source' -ErrorAction SilentlyContinue |
				Where-Object { -not (Test-ExcludedPath $_.FullName) } |
				ForEach-Object { $SourceDirs.Add($_.FullName) }
		}
	}

	$CodeFiles = New-Object System.Collections.Generic.List[string]

	foreach ($sourceDir in $SourceDirs)
	{
		Get-ChildItem -LiteralPath $sourceDir -Recurse -Include '*.h', '*.cpp' -File -ErrorAction SilentlyContinue |
			Where-Object { -not (Test-ExcludedPath $_.FullName) } |
			ForEach-Object { $CodeFiles.Add($_.FullName) }
	}

	# 头文件必须全部先于 cpp 处理：否则 .cpp 可能先于其 .h 被读到，
	# 声明表里查不到该常量，会误报「缺模块导出宏」（实测假阳性，21/21 条）。
	$OrderedFiles = New-Object System.Collections.Generic.List[string]

	foreach ($codeFile in $CodeFiles)
	{
		if ([System.IO.Path]::GetExtension($codeFile) -eq '.h')
		{
			$OrderedFiles.Add($codeFile)
		}
	}

	foreach ($codeFile in $CodeFiles)
	{
		if ([System.IO.Path]::GetExtension($codeFile) -ne '.h')
		{
			$OrderedFiles.Add($codeFile)
		}
	}

	$CodeFiles = $OrderedFiles

	$DefinePattern = 'UE_DEFINE_GAMEPLAY_TAG(?<variant>_COMMENT|_STATIC)?\s*\(\s*(?<constant>[A-Za-z_]\w*)\s*,\s*"(?<tag>[^"]+)"'
	$DeclareMacroPattern = 'UE_DECLARE_GAMEPLAY_TAG_EXTERN\s*\(\s*(?<constant>[A-Za-z_]\w*)\s*\)'
	$ExternPattern = 'extern\s+(?<type>[A-Za-z_]\w*)\s+FNativeGameplayTag\s+(?<constant>[A-Za-z_]\w*)\s*;'

	foreach ($codeFile in $CodeFiles)
	{
		$extension = [System.IO.Path]::GetExtension($codeFile)
		$lineNumber = 0

		foreach ($line in (Get-Content -LiteralPath $codeFile -Encoding UTF8))
		{
			$lineNumber++
			$relative = Get-RelativePath $ProjectRoot $codeFile

			if ($extension -eq '.h')
			{
				$declareMatch = [regex]::Match($line, $DeclareMacroPattern)
				if ($declareMatch.Success)
				{
					$HeaderDeclarations[$declareMatch.Groups['constant'].Value] = [pscustomobject]@{
						HasExportMacro = $false
						Location       = "${relative}:${lineNumber}"
					}
					continue
				}

				$externMatch = [regex]::Match($line, $ExternPattern)
				if ($externMatch.Success)
				{
					$HeaderDeclarations[$externMatch.Groups['constant'].Value] = [pscustomobject]@{
						HasExportMacro = $externMatch.Groups['type'].Value.EndsWith('_API')
						Location       = "${relative}:${lineNumber}"
					}
				}

				continue
			}

			$defineMatch = [regex]::Match($line, $DefinePattern)
			if (-not $defineMatch.Success)
			{
				continue
			}

			$constant = $defineMatch.Groups['constant'].Value
			$declaration = $HeaderDeclarations[$constant]

			$TagRecords.Add([pscustomobject]@{
					Tag            = $defineMatch.Groups['tag'].Value
					Source         = 'native'
					Comment        = $(if ($defineMatch.Groups['variant'].Value -eq '_COMMENT') { '<inline>' } else { '' })
					ConstantName   = $constant
					HasExportMacro = $(if ($null -ne $declaration) { $declaration.HasExportMacro } else { $false })
					Location       = "${relative}:${lineNumber}"
				})
		}
	}
}

# ---------------------------------------------------------------- 检查

if ($TagRecords.Count -eq 0)
{
	Write-Warning '未采集到任何 gameplay tag 声明。检查 ProjectRoot 是否正确。'
	exit 2
}

foreach ($record in $TagRecords)
{
	$tag = $record.Tag
	$location = $record.Location

	if ([string]::IsNullOrWhiteSpace($tag))
	{
		Add-Issue Error 'D5-空段' $tag 'tag 文本为空' $location
		continue
	}

	$segments = $tag.Split('.')

	# 1 深度
	if ($segments.Count -gt $MaxDepth)
	{
		Add-Issue Error 'D1-深度超限' $tag "段数 $($segments.Count) > 上限 $MaxDepth" $location
	}

	# 2/3/4/5 逐段字符检查
	for ($i = 0; $i -lt $segments.Count; $i++)
	{
		$segment = $segments[$i]

		if ([string]::IsNullOrEmpty($segment))
		{
			Add-Issue Error 'D5-空段' $tag "段 $($i + 1) 为空（连续点或首尾点）" $location
			continue
		}

		if ($segment.Contains('_'))
		{
			Add-Issue Error 'D2-段内下划线' $tag "段 $($i + 1) '$segment' 含下划线（应 PascalCase，且下划线会破坏常量名逐段反推）" $location
		}

		if ($segment -match '[^\x20-\x7E]')
		{
			Add-Issue Error 'D3-非ASCII' $tag "段 $($i + 1) '$segment' 含非 ASCII 字符" $location
		}

		if ($segment -match '["'',\s]')
		{
			Add-Issue Error 'D4-引擎非法字符' $tag "段 $($i + 1) '$segment' 含引擎硬非法字符（双引号 / 单引号 / 逗号 / 空白）" $location
		}
	}

	# 6 命名空间
	if (-not [string]::IsNullOrEmpty($Namespace) -and $segments.Count -gt 1)
	{
		if ($segments[0] -ne $Namespace)
		{
			Add-Issue Error 'D6-命名空间不符' $tag "首段 '$($segments[0])' 与约定 '$Namespace' 不符" $location
		}
	}

	# 7 生命周期/阶段类段
	for ($i = 1; $i -lt $segments.Count; $i++)
	{
		$segment = $segments[$i]

		if ($ForbiddenSegments -notcontains $segment)
		{
			continue
		}

		if ($i -eq 1 -and $segment -eq $ProbeDomain)
		{
			continue
		}

		Add-Issue Error 'D7-生命周期段入路径' $tag "段 $($i + 1) '$segment' 是生命周期/阶段维度，不得作层级段（临时词应落 $ProbeDomain 域）" $location
	}

	# 8 ini 词缺 DevComment
	if ($record.Source -eq 'ini' -and [string]::IsNullOrWhiteSpace($record.Comment))
	{
		Add-Issue Warning 'A1-缺DevComment' $tag 'ini 词未提供 DevComment（应写语义 / 归属 / 退役判据）' $location
	}

	# 12 原生用无注释宏
	if ($record.Source -eq 'native' -and [string]::IsNullOrWhiteSpace($record.Comment))
	{
		Add-Issue Info 'A4-原生无注释' $tag '原生 tag 用 UE_DEFINE_GAMEPLAY_TAG（无注释），建议改用 UE_DEFINE_GAMEPLAY_TAG_COMMENT' $location
	}

	# 10 原生声明缺模块导出宏
	if ($record.Source -eq 'native' -and $null -ne $record.ConstantName -and $record.ConstantName -ne '' -and -not $record.HasExportMacro)
	{
		$declaration = $HeaderDeclarations[$record.ConstantName]
		if ($null -ne $declaration)
		{
			Add-Issue Warning 'A2-缺模块导出宏' $tag "声明处 $($declaration.Location) 未带模块导出宏（裸 extern），跨模块引用会 LNK2001" $location
		}
	}

	# 11 常量名与 tag 文本不逐段对应
	if ($record.Source -eq 'native' -and -not [string]::IsNullOrEmpty($record.ConstantName))
	{
		if ((Get-NormalizedTagToken $record.ConstantName) -ne (Get-NormalizedTagToken $tag))
		{
			Add-Issue Warning 'A3-常量名不对应' $tag "常量名 '$($record.ConstantName)' 与 tag 文本不逐段对应（点→下划线）" $location
		}
	}
}

# 9 同一 tag 文本多处声明
$TagRecords |
	Group-Object -Property { $_.Tag.ToLowerInvariant() } |
	Where-Object { $_.Count -gt 1 } |
	ForEach-Object {
		$locations = ($_.Group | ForEach-Object { "$($_.Location) [$($_.Source)]" }) -join '; '
		Add-Issue Error 'A5-重复声明' $_.Group[0].Tag "同一 tag 文本有 $($_.Count) 处声明：$locations" $locations
	}

# ---------------------------------------------------------------- 报告

$errors = @($script:Issues | Where-Object { $_.Level -eq 'Error' })
$warnings = @($script:Issues | Where-Object { $_.Level -eq 'Warning' })
$infos = @($script:Issues | Where-Object { $_.Level -eq 'Info' })

Write-Host ''
Write-Host "GameplayTag 校验：$ProjectRoot" -ForegroundColor Cyan
Write-Host "采集 $($TagRecords.Count) 条声明（ini $((@($TagRecords | Where-Object { $_.Source -eq 'ini' })).Count) / native $((@($TagRecords | Where-Object { $_.Source -eq 'native' })).Count)）；上限 $MaxDepth 段" -ForegroundColor DarkGray
Write-Host ''

if ($script:Issues.Count -eq 0)
{
	Write-Host '零违规。' -ForegroundColor Green
	exit 0
}

foreach ($level in @('Error', 'Warning', 'Info'))
{
	$group = @($script:Issues | Where-Object { $_.Level -eq $level })

	if ($group.Count -eq 0)
	{
		continue
	}

	$color = switch ($level)
	{
		'Error' { 'Red' }
		'Warning' { 'Yellow' }
		default { 'DarkGray' }
	}

	Write-Host "── $level ($($group.Count)) ──" -ForegroundColor $color

	$group |
		Sort-Object Check, Tag |
		ForEach-Object {
			Write-Host ("  [{0}] {1}" -f $_.Check, $_.Tag) -ForegroundColor $color
			Write-Host ("        {0}" -f $_.Detail) -ForegroundColor DarkGray
			Write-Host ("        @ {0}" -f $_.Location) -ForegroundColor DarkGray
		}

	Write-Host ''
}

Write-Host ("合计：Error $($errors.Count) / Warning $($warnings.Count) / Info $($infos.Count)") -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ''
Write-Host '脚本查不出的项（必须人工）：域判据是否成立、词归哪个域、DevComment 内容是否真实、Probe 退役判据是否合理、隐式父节点造成的静默降级。' -ForegroundColor DarkGray

if ($errors.Count -gt 0)
{
	exit 1
}

exit 0
