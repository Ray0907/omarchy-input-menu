# fcitx5 classicui theme rendered by Omarchy from the active theme's colors.
# Same look as Input Menu's menu: accent border, accent-filled highlight with the
# background color as its text.
[Metadata]
Name=Omarchy Input Menu
Version=1
Author=omarchy-input-menu
Description=Follows the active Omarchy theme
ScaleWithDPI=True

[InputPanel]
NormalColor={{ foreground }}
HighlightCandidateColor={{ background }}
HighlightColor={{ foreground }}
HighlightBackgroundColor={{ selection }}
PageButtonAlignment=Last Candidate

[InputPanel/TextMargin]
Left=6
Right=6
Top=4
Bottom=4

[InputPanel/ContentMargin]
Left=4
Right=4
Top=4
Bottom=4

[InputPanel/Background]
Color={{ background }}
BorderColor={{ accent }}
BorderWidth=2

[InputPanel/Background/Margin]
Left=2
Right=2
Top=2
Bottom=2

[InputPanel/Highlight]
Color={{ accent }}

[InputPanel/Highlight/Margin]
Left=6
Right=6
Top=4
Bottom=4

[InputPanel/PrevPage]
Image=prev.svg

[InputPanel/PrevPage/ClickMargin]
Left=5
Right=5
Top=4
Bottom=4

[InputPanel/NextPage]
Image=next.svg

[InputPanel/NextPage/ClickMargin]
Left=5
Right=5
Top=4
Bottom=4

[Menu]
NormalColor={{ foreground }}
HighlightCandidateColor={{ background }}

[Menu/Background]
Color={{ background }}
BorderColor={{ accent }}
BorderWidth=2

[Menu/Background/Margin]
Left=2
Right=2
Top=2
Bottom=2

[Menu/ContentMargin]
Left=2
Right=2
Top=2
Bottom=2

[Menu/CheckBox]
Image=radio.svg

[Menu/SubMenu]
Image=arrow.svg

[Menu/Highlight]
Color={{ accent }}

[Menu/Highlight/Margin]
Left=5
Right=5
Top=5
Bottom=5

[Menu/Separator]
Color={{ muted }}

[Menu/TextMargin]
Left=5
Right=5
Top=5
Bottom=5
