Archive Migration has moved 14 of its 20 tables, so 6 tables remain. Most of the work is therefore done, but one blocker now affects part of what is left.

The export tool times out on files larger than 2 GB. Because of that timeout, three of the remaining tables are blocked and cannot be exported yet. The blocker does not apply to the other 3 remaining tables, so it holds back three of the 6 tables still to move.

The next step is to split large files before export. The data team owns this step, and its target is the end of the current sprint. Splitting the files is aimed at the three blocked tables, which cannot be exported while files larger than 2 GB still cause the export tool to time out.
