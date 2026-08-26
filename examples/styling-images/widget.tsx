import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Images",
  size: [780, 390],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <stack class="size-full pl-[30px] pt-[10px] pr-[30px] pb-[50px]">
  <column class="w-[720px] h-[330px] p-5 gap-4 bg-slate-950 rounded-2xl border border-slate-700 shadow-xl">
    <column class="gap-1">
      <text class="text-xl font-semibold text-white">Image fit and masks</text>
      <text class="text-sm text-slate-400">One local asset, three exact projection paths</text>
    </column>
    <row class="grow gap-4">
      <column class="grow gap-2">
        <image src="./assets/weaver.png" fit="cover" class="w-full grow rounded-tl-3xl rounded-tr-md rounded-br-2xl rounded-bl-lg" />
        <text class="text-sm font-medium text-slate-200">cover · asymmetric radius</text>
      </column>
      <column class="grow gap-2">
        <image src="./assets/weaver.png" fit="contain" class="w-full grow bg-slate-900 rounded-2xl border border-slate-700" />
        <text class="text-sm font-medium text-slate-200">contain · rounded mask</text>
      </column>
      <column class="grow gap-2">
        <image src="./assets/weaver.png" tile class="w-full grow rounded-xl border border-indigo-400" />
        <text class="text-sm font-medium text-slate-200">tile · natural size</text>
      </column>
    </row>
  </column>
  </stack>
));
